#![no_std]
#![no_main]

//! Put the boot loader on a system that has just been installed.
//!
//! ```text
//! bang-install ROOT
//! ```
//!
//! `ROOT` is where the new system's root filesystem is mounted, with its EFI
//! system partition mounted on `ROOT/boot`. What the firmware starts is
//! copied there from the new system's own `/usr/lib/explosion/boot` — Bang,
//! the kernel, and the modules Bang hands it, the services a system runs
//! before it has a root among them — and two files are written:
//!
//! - `bang.cfg`, the menu;
//! - `drivers/root.cfg`, which says where the root is. Only an installer
//!   knows that: it is the partition this was told to install to, and
//!   `init` reads it out of the modules to tell the file server.
//!
//! Firmware finds Bang by where it is — `\EFI\BOOT\BOOTX64.EFI`, the name it
//! tries on any disk it is told to start from — so nothing is written to the
//! firmware's own settings, and nothing here could.

use quark_rt::{args, block, nameserver, println, syscall, vfs};

const MAX_PATH: usize = 512;
const SOURCE: &[u8] = b"usr/lib/explosion/boot";

fn text(bytes: &[u8]) -> &str {
    core::str::from_utf8(bytes).unwrap_or("?")
}

fn fail(what: core::fmt::Arguments) -> ! {
    println!("bang-install: {}", what);
    syscall::sys_exit_code(1);
}

/// Paths joined with one slash between each, into `out`.
fn join<'a>(parts: &[&[u8]], out: &'a mut [u8; MAX_PATH]) -> &'a [u8] {
    let mut len = 0;
    for part in parts {
        let part = part.strip_prefix(b"/").unwrap_or(part);
        let part = part.strip_suffix(b"/").unwrap_or(part);
        if part.is_empty() {
            continue;
        }
        if len + 1 + part.len() > out.len() {
            fail(format_args!("a path is too long"));
        }
        out[len] = b'/';
        out[len + 1..len + 1 + part.len()].copy_from_slice(part);
        len += 1 + part.len();
    }
    if len == 0 {
        out[0] = b'/';
        len = 1;
    }
    &out[..len]
}

/// `path` written out whole, as `mount` writes down where a filesystem is.
fn whole(vfs_tid: usize, path: &[u8], out: &mut [u8; MAX_PATH]) -> usize {
    let mut from = [0u8; MAX_PATH];
    let mut from_len = 0;
    if path.first() != Some(&b'/') {
        from_len = vfs::getcwd(vfs_tid, &mut from).unwrap_or(0);
    }
    let mut len = 0;
    for part in from[..from_len].split(|&b| b == b'/').chain(path.split(|&b| b == b'/')) {
        match part {
            b"" | b"." => {}
            b".." => {
                while len > 0 && out[len - 1] != b'/' {
                    len -= 1;
                }
                len = len.saturating_sub(1);
            }
            _ if len + 1 + part.len() <= out.len() => {
                out[len] = b'/';
                out[len + 1..len + 1 + part.len()].copy_from_slice(part);
                len += 1 + part.len();
            }
            _ => fail(format_args!("a path is too long")),
        }
    }
    if len == 0 {
        out[0] = b'/';
        len = 1;
    }
    len
}

/// What is mounted on `target`: where it came from, and of what kind.
fn mounted_on(vfs_tid: usize, target: &[u8], source: &mut [u8; 64]) -> Option<(usize, u64)> {
    let mut record = [0u8; 512];
    for index in 0.. {
        let m = vfs::mounted(vfs_tid, index, &mut record).ok()??;
        let (from, at) = vfs::mount_record(&record[..m.len]);
        if at == target && from.len() <= source.len() {
            source[..from.len()].copy_from_slice(from);
            return Some((from.len(), m.kind));
        }
    }
    None
}

/// A device's name taken apart: `/dev/disk0p2` is volume 2 of the driver
/// `disk0`, and a name with no partition in it is the whole of its disk.
fn volume_of(source: &[u8]) -> (&[u8], &[u8]) {
    let device = source.strip_prefix(b"/dev/").unwrap_or(source);
    match device.iter().rposition(|&b| b == b'p') {
        Some(at) if at > 0 && at + 1 < device.len() && device[at + 1..].iter().all(u8::is_ascii_digit) => {
            (&device[..at], &device[at + 1..])
        }
        _ => (device, &b"0"[..]),
    }
}

/// Copy a file. The name it is given is the name it has on a FAT filesystem,
/// which keeps eight characters and three and no case.
fn copy(vfs_tid: usize, from: &[u8], to: &[u8]) -> u64 {
    let Ok((src, _, false)) = vfs::open(vfs_tid, from) else {
        fail(format_args!("{} is not there to copy", text(from)));
    };
    let dst = match vfs::open_with(vfs_tid, to, vfs::OPEN_CREATE | vfs::OPEN_TRUNCATE) {
        Ok(o) => o.handle,
        Err(code) => fail(format_args!("{} could not be made ({})", text(to), code)),
    };
    let mut page = [0u8; 4096];
    let mut at = 0u64;
    loop {
        let n = match vfs::read(vfs_tid, src, &mut page, at as u32) {
            Ok(0) => break,
            Ok(n) => n as usize,
            Err(code) => fail(format_args!("{} could not be read ({})", text(from), code)),
        };
        let mut put = 0;
        while put < n {
            match vfs::write(vfs_tid, dst, &page[put..n], (at + put as u64) as u32) {
                Ok(w) if w > 0 => put += w as usize,
                _ => fail(format_args!("{} could not be written: is the partition full?", text(to))),
            }
        }
        at += n as u64;
    }
    let _ = vfs::close(vfs_tid, src);
    let _ = vfs::close(vfs_tid, dst);
    at
}

fn make_dir(vfs_tid: usize, path: &[u8]) {
    match vfs::mkdir(vfs_tid, path) {
        // FAT's server says a name that is taken is an invalid one.
        Ok(()) | Err(vfs::ERR_EXISTS) | Err(vfs::ERR_INVALID_PATH) => {}
        Err(code) => fail(format_args!("{} could not be made ({})", text(path), code)),
    }
}

#[unsafe(no_mangle)]
#[link_section = ".text.entry"]
pub extern "C" fn _start() -> ! {
    let (Some(arg), None) = (args::argv(1), args::argv(2)) else {
        println!("usage: bang-install ROOT");
        println!("ROOT is where the new system is mounted, its EFI partition on ROOT/boot.");
        syscall::sys_exit_code(2);
    };
    let Some(vfs_tid) = nameserver::lookup_retry(b"vfs", 20) else {
        fail(format_args!("there is no file server"));
    };
    let mut root = [0u8; MAX_PATH];
    let root_len = whole(vfs_tid, arg, &mut root);
    let root = &root[..root_len];

    // Where the root is: the partition mounted on ROOT, as `mount` wrote it
    // down.
    let mut source = [0u8; 64];
    let Some((source_len, _)) = mounted_on(vfs_tid, root, &mut source) else {
        fail(format_args!("nothing is mounted on {}: mount the new system's root there", text(root)));
    };
    let (driver, volume) = volume_of(&source[..source_len]);

    let mut buf = [0u8; MAX_PATH];
    let boot_len = join(&[root, b"boot"], &mut buf).len();
    let mut boot = [0u8; MAX_PATH];
    boot[..boot_len].copy_from_slice(&buf[..boot_len]);
    let boot = &boot[..boot_len];
    let mut esp = [0u8; 64];
    let esp_len = match mounted_on(vfs_tid, boot, &mut esp) {
        Some((len, vfs::KIND_FAT)) => len,
        Some(_) => fail(format_args!(
            "{} is not a FAT filesystem, and firmware reads no other: make one with mkfs.fat",
            text(boot)
        )),
        None => fail(format_args!("nothing is mounted on {}: mount the EFI system partition there", text(boot))),
    };
    // A FAT filesystem is what firmware can read. A partition that says it
    // is the EFI system partition is where firmware looks, and not every
    // firmware looks anywhere else: ask the driver what this one says.
    let (esp_driver, esp_volume) = volume_of(&esp[..esp_len]);
    let esp_number = esp_volume.iter().fold(0u64, |n, d| n.saturating_mul(10).saturating_add((d - b'0') as u64));
    let unmarked = nameserver::lookup(esp_driver)
        .and_then(|tid| block::info(tid, esp_number).ok())
        .is_some_and(|i| i.kind == block::KIND_DATA || i.kind == block::KIND_OTHER);

    let mut from = [0u8; MAX_PATH];
    let mut to = [0u8; MAX_PATH];
    let here = |name: &[u8], out: &mut [u8; MAX_PATH]| join(&[root, SOURCE, name], out).len();
    let n = here(b"BOOTX64.EFI", &mut from);
    if vfs::open(vfs_tid, &from[..n]).map(|(h, _, _)| vfs::close(vfs_tid, h)).is_err() {
        fail(format_args!(
            "{} has no boot files in /{}: `qpkg strap {} base` puts them there",
            text(root),
            text(SOURCE),
            text(root)
        ));
    }

    let mut bytes = 0;
    for dir in [&b"EFI"[..], b"EFI/BOOT", b"DRIVERS"] {
        make_dir(vfs_tid, join(&[boot, dir], &mut to));
    }
    for (name, place) in [(&b"BOOTX64.EFI"[..], &b"EFI/BOOT/BOOTX64.EFI"[..]), (b"kernel.bin", b"KERNEL.BIN"), (b"bang.cfg", b"BANG.CFG")] {
        let n = here(name, &mut from);
        bytes += copy(vfs_tid, &from[..n], join(&[boot, place], &mut to));
    }
    // The modules: whatever the system has in its drivers directory.
    let n = here(b"drivers", &mut from);
    let Ok((dir, _, true)) = vfs::open(vfs_tid, &from[..n]) else {
        fail(format_args!("{} has no modules to boot with", text(&from[..n])));
    };
    let mut entries = [vfs::DirEntry::empty(); 16];
    let mut next = 0;
    let mut modules = 0;
    loop {
        let Ok(page) = vfs::readdir_bulk(vfs_tid, dir, next, &mut entries) else { break };
        for e in entries[..page.count].iter().filter(|e| !e.is_dir) {
            let mut name = [0u8; 32];
            let len = e.name_len.min(name.len());
            name[..len].copy_from_slice(&e.name_bytes()[..len]);
            let mut src = [0u8; MAX_PATH];
            let src_len = join(&[root, SOURCE, b"drivers", &name[..len]], &mut src).len();
            name[..len].make_ascii_uppercase();
            bytes += copy(vfs_tid, &src[..src_len], join(&[boot, b"DRIVERS", &name[..len]], &mut to));
            modules += 1;
        }
        next = page.next;
        if page.end {
            break;
        }
    }
    let _ = vfs::close(vfs_tid, dir);

    // Where the root is, for init to tell the file server.
    let mut line = [0u8; 64];
    let mut len = 0;
    for part in [&b"root "[..], driver, b" ", volume, b"\n"] {
        line[len..len + part.len()].copy_from_slice(part);
        len += part.len();
    }
    let cfg = join(&[boot, b"DRIVERS/ROOT.CFG"], &mut to);
    let wrote = vfs::open_with(vfs_tid, cfg, vfs::OPEN_CREATE | vfs::OPEN_TRUNCATE).and_then(|o| {
        let wrote = vfs::write(vfs_tid, o.handle, &line[..len], 0);
        let _ = vfs::close(vfs_tid, o.handle);
        wrote
    });
    if wrote != Ok(len as u32) {
        fail(format_args!("{} could not be written", text(cfg)));
    }

    // A write is answered a moment before it is recorded for good, and what
    // this is about to say is that it has been.
    let _ = vfs::sync(vfs_tid);
    println!(
        "Bang, the kernel and {} modules ({} KiB) are on {}.",
        modules,
        bytes / 1024,
        text(boot)
    );
    println!("The system it starts has its root on {}.", text(&source[..source_len]));
    if unmarked {
        println!(
            "Note: {} is not marked as an EFI system partition, and some firmware starts",
            text(&esp[..esp_len])
        );
        println!("only from one that is. `parts {}` shows what each partition is.", text(esp_driver));
    }
    syscall::sys_exit_code(0);
}

#[panic_handler]
fn panic(info: &core::panic::PanicInfo) -> ! {
    println!("bang-install: {}", info);
    syscall::sys_exit_code(255);
}
