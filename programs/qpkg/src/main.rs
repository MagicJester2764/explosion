#![no_std]
#![no_main]

//! What this system is made of, and how to make another.
//!
//! ```text
//! qpkg                    the packages here
//! qpkg info NAME          what one is, and what its programs may do
//! qpkg files NAME         the files it owns
//! qpkg owner PATH         which package a file is from
//! qpkg verify [NAME...]   whether the files are still what was built
//! qpkg sets               the sets packages come in
//! qpkg strap ROOT SET...  put those sets' packages into another root
//! ```
//!
//! A package is a list: `/var/lib/qpkg/NAME` says what the package is, which
//! *set* it belongs to, every file it owns with its length and a checksum,
//! and — for every program among them — what that program asks the system
//! to let it do. Those requests are compiled into each program and are what
//! a spawner grants from; the list says them out loud, so that what a
//! package may do is read before it is installed and not found out after.
//!
//! `strap` is how a system makes another: it copies the packages of the sets
//! asked for from the running system into a root that has been mounted
//! somewhere, with their lists. The system that results knows what it is
//! made of in the same way, and can do the same.

use quark_rt::{args, nameserver, print, println, syscall, vfs};

// No manifest: reading and writing files takes buffers to lend the file
// server, and nothing else.

const DB: &[u8] = b"/var/lib/qpkg";

/// Where a package's list is read to, and how long one may be.
const RECORD_AT: usize = 0x9A_0000_0000;
const RECORD_PAGES: usize = 256;
const RECORD_MAX: usize = RECORD_PAGES * 4096;
/// The names of the directories a strap has put files in, to give each its
/// times back when the files are all there.
const DIRS_AT: usize = 0x9B_0000_0000;
const DIRS_PAGES: usize = 64;
const DIRS_MAX: usize = DIRS_PAGES * 4096;

const MAX_PACKAGES: usize = 64;
const MAX_NAME: usize = 48;
const MAX_PATH: usize = 1024;

fn text(bytes: &[u8]) -> &str {
    core::str::from_utf8(bytes).unwrap_or("?")
}

fn fail(what: core::fmt::Arguments) -> ! {
    println!("qpkg: {}", what);
    syscall::sys_exit_code(1);
}

/// What the file server's refusals mean, to somebody reading them.
fn why(code: u64) -> &'static str {
    match code {
        vfs::ERR_NOT_FOUND => "it is not there",
        vfs::ERR_PERMISSION => "permission denied",
        vfs::ERR_NO_SPACE => "there is no room left",
        vfs::ERR_READ_ONLY => "the filesystem is read-only",
        vfs::ERR_NOT_DIR => "something in the path is not a directory",
        vfs::ERR_IO => "the disk, or the server of a mounted filesystem, failed",
        vfs::ERR_NAME_TOO_LONG => "the name is too long",
        vfs::ERR_NOT_SUPPORTED => "the filesystem cannot do that",
        _ => "the file server refused",
    }
}

fn record() -> &'static mut [u8] {
    unsafe { core::slice::from_raw_parts_mut(RECORD_AT as *mut u8, RECORD_MAX) }
}

/// Two paths as one, into `out`.
fn join<'a>(a: &[u8], b: &[u8], out: &'a mut [u8; MAX_PATH]) -> Option<&'a [u8]> {
    let a = if a.len() > 1 && a.ends_with(b"/") { &a[..a.len() - 1] } else { a };
    let a = if a == b"/" { &b""[..] } else { a };
    let slash = !b.starts_with(b"/") as usize;
    let len = a.len() + slash + b.len();
    if len > out.len() {
        return None;
    }
    out[..a.len()].copy_from_slice(a);
    if slash == 1 {
        out[a.len()] = b'/';
    }
    out[a.len() + slash..len].copy_from_slice(b);
    Some(&out[..len])
}

/// The whole of a file, into `into`. How much there was.
fn slurp(vfs_tid: usize, path: &[u8], into: &mut [u8]) -> Result<usize, u64> {
    let (handle, _, _) = vfs::open(vfs_tid, path)?;
    let mut got = 0;
    let result = loop {
        if got == into.len() {
            break Err(vfs::ERR_NAME_TOO_LONG);
        }
        match vfs::read(vfs_tid, handle, &mut into[got..], got as u32) {
            Ok(0) => break Ok(got),
            Ok(n) => got += n as usize,
            Err(code) => break Err(code),
        }
    };
    let _ = vfs::close(vfs_tid, handle);
    result
}

/// The names of the packages here, in order.
struct Names {
    names: [[u8; MAX_NAME]; MAX_PACKAGES],
    lens: [usize; MAX_PACKAGES],
    count: usize,
}

impl Names {
    fn read(vfs_tid: usize) -> Names {
        let mut all = Names { names: [[0; MAX_NAME]; MAX_PACKAGES], lens: [0; MAX_PACKAGES], count: 0 };
        let Ok((dir, _, true)) = vfs::open(vfs_tid, DB) else {
            fail(format_args!("there are no package lists in {}", text(DB)));
        };
        let mut entries = [vfs::DirEntry::empty(); 16];
        let mut next = 0;
        loop {
            let Ok(page) = vfs::readdir_bulk(vfs_tid, dir, next, &mut entries) else { break };
            for e in &entries[..page.count] {
                let name = e.name_bytes();
                if name.starts_with(b".") || name.len() > MAX_NAME || all.count == MAX_PACKAGES || e.is_dir {
                    continue;
                }
                // In order: there are few, and each goes where it belongs.
                let mut at = all.count;
                while at > 0 && &all.names[at - 1][..all.lens[at - 1]] > name {
                    all.names[at] = all.names[at - 1];
                    all.lens[at] = all.lens[at - 1];
                    at -= 1;
                }
                all.names[at] = [0; MAX_NAME];
                all.names[at][..name.len()].copy_from_slice(name);
                all.lens[at] = name.len();
                all.count += 1;
            }
            next = page.next;
            if page.end {
                break;
            }
        }
        let _ = vfs::close(vfs_tid, dir);
        all
    }

    fn get(&self, i: usize) -> &[u8] {
        &self.names[i][..self.lens[i]]
    }
}

/// A package's list, read into the record buffer.
fn load(vfs_tid: usize, name: &[u8]) -> Result<&'static [u8], u64> {
    let mut path = [0u8; MAX_PATH];
    // A name is a name, not a way out of the directory the lists are in.
    if name.is_empty() || name.contains(&b'/') || name.starts_with(b".") {
        return Err(vfs::ERR_NOT_FOUND);
    }
    let path = join(DB, name, &mut path).ok_or(vfs::ERR_NAME_TOO_LONG)?;
    let buf = record();
    let len = slurp(vfs_tid, path, buf)?;
    Ok(&buf[..len])
}

/// One line of a list.
enum Line<'a> {
    /// `name`, `version`, `set`, `about`: what the package is.
    Says(&'a [u8], &'a [u8]),
    /// `d MODE PATH`: a directory the package wants there.
    Dir(u32, &'a [u8]),
    /// `f CRC SIZE PATH`: a file it owns.
    File(u32, u64, &'a [u8]),
    /// `l PATH`: a symbolic link it owns.
    Link(&'a [u8]),
    /// `c PATH WHAT`: what a program of it asks to be allowed.
    May(&'a [u8], &'a [u8]),
}

fn number(digits: &[u8], radix: u64) -> Option<u64> {
    if digits.is_empty() {
        return None;
    }
    digits.iter().try_fold(0u64, |n, &c| {
        let d = (c as char).to_digit(radix as u32)? as u64;
        n.checked_mul(radix)?.checked_add(d)
    })
}

/// A line's first word, and what follows the space after it.
fn split(s: &[u8]) -> Option<(&[u8], &[u8])> {
    let at = s.iter().position(|&b| b == b' ')?;
    Some((&s[..at], &s[at + 1..]))
}

fn lines(list: &[u8]) -> impl Iterator<Item = Line<'_>> {
    list.split(|&b| b == b'\n').filter_map(|line| {
        let (key, rest) = split(line)?;
        Some(match key {
            b"d" => {
                let (mode, path) = split(rest)?;
                Line::Dir(number(mode, 8)? as u32, path)
            }
            b"f" => {
                let (crc, rest) = split(rest)?;
                let (size, path) = split(rest)?;
                Line::File(number(crc, 16)? as u32, number(size, 10)?, path)
            }
            b"l" => Line::Link(rest),
            b"c" => {
                let (path, what) = split(rest)?;
                Line::May(path, what)
            }
            _ => Line::Says(key, rest),
        })
    })
}

/// What a list says for `key`.
fn said<'a>(list: &'a [u8], key: &[u8]) -> &'a [u8] {
    lines(list)
        .find_map(|l| match l {
            Line::Says(k, v) if k == key => Some(v),
            _ => None,
        })
        .unwrap_or(b"")
}

/// How many files and links a list has, and how many bytes the files are.
fn weight(list: &[u8]) -> (usize, u64) {
    lines(list).fold((0, 0), |(n, bytes), l| match l {
        Line::File(_, size, _) => (n + 1, bytes + size),
        Line::Link(_) => (n + 1, bytes),
        _ => (n, bytes),
    })
}

/// A size as people say it.
struct Size(u64);

impl core::fmt::Display for Size {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        use core::fmt::Write;
        // Written out first and then handed over whole: `write!` straight
        // to the formatter takes no notice of the width a column asked for.
        struct Text([u8; 24], usize);
        impl Write for Text {
            fn write_str(&mut self, s: &str) -> core::fmt::Result {
                let n = s.len().min(self.0.len() - self.1);
                self.0[self.1..self.1 + n].copy_from_slice(&s.as_bytes()[..n]);
                self.1 += n;
                Ok(())
            }
        }
        let mut out = Text([0; 24], 0);
        match self.0 {
            n if n >= 10 << 20 => write!(out, "{} MiB", n >> 20),
            n if n >= 1 << 20 => write!(out, "{}.{} MiB", n >> 20, (n & 0xFFFFF) * 10 >> 20),
            n if n >= 1 << 10 => write!(out, "{} KiB", n >> 10),
            n => write!(out, "{} B", n),
        }?;
        f.pad(core::str::from_utf8(&out.0[..out.1]).unwrap_or(""))
    }
}

fn list_all(vfs_tid: usize) -> ! {
    let names = Names::read(vfs_tid);
    println!("{:<12} {:<9} {:<8} {:>6} {:>10}", "PACKAGE", "SET", "VERSION", "FILES", "SIZE");
    for i in 0..names.count {
        let Ok(list) = load(vfs_tid, names.get(i)) else { continue };
        let (files, bytes) = weight(list);
        println!(
            "{:<12} {:<9} {:<8} {:>6} {:>10}",
            text(names.get(i)),
            text(said(list, b"set")),
            text(said(list, b"version")),
            files,
            Size(bytes)
        );
    }
    syscall::sys_exit_code(0);
}

fn sets(vfs_tid: usize) -> ! {
    let names = Names::read(vfs_tid);
    // Each set once, with what is in it.
    let mut shown = [[0u8; MAX_NAME]; MAX_PACKAGES];
    let mut shown_lens = [0usize; MAX_PACKAGES];
    let mut count = 0;
    for i in 0..names.count {
        let Ok(list) = load(vfs_tid, names.get(i)) else { continue };
        let set = said(list, b"set");
        if set.is_empty() || set.len() > MAX_NAME || (0..count).any(|s| &shown[s][..shown_lens[s]] == set) {
            continue;
        }
        shown[count][..set.len()].copy_from_slice(set);
        shown_lens[count] = set.len();
        count += 1;
    }
    for s in 0..count {
        let set = &shown[s][..shown_lens[s]];
        print!("{:<9}", text(set));
        let mut bytes = 0;
        for i in 0..names.count {
            if let Ok(list) = load(vfs_tid, names.get(i)) {
                if said(list, b"set") == set {
                    print!(" {}", text(names.get(i)));
                    bytes += weight(list).1;
                }
            }
        }
        println!("  ({})", Size(bytes));
    }
    syscall::sys_exit_code(0);
}

fn info(vfs_tid: usize, name: &[u8]) -> ! {
    let Ok(list) = load(vfs_tid, name) else {
        fail(format_args!("there is no package called {}", text(name)));
    };
    let (files, bytes) = weight(list);
    println!("{} {}", text(name), text(said(list, b"version")));
    println!("  {}", text(said(list, b"about")));
    println!("  set {}, {} files, {}", text(said(list, b"set")), files, Size(bytes));
    let mut any = false;
    for line in lines(list) {
        if let Line::May(path, what) = line {
            if !any {
                println!("What its programs ask to be allowed:");
                any = true;
            }
            println!("  {:<28} {}", text(path), text(what));
        }
    }
    if !any {
        println!("Its programs ask for nothing: they have what any program has.");
    }
    syscall::sys_exit_code(0);
}

fn files(vfs_tid: usize, name: &[u8]) -> ! {
    let Ok(list) = load(vfs_tid, name) else {
        fail(format_args!("there is no package called {}", text(name)));
    };
    for line in lines(list) {
        match line {
            Line::File(_, _, path) | Line::Link(path) => println!("{}", text(path)),
            _ => {}
        }
    }
    syscall::sys_exit_code(0);
}

fn owner(vfs_tid: usize, path: &[u8]) -> ! {
    let names = Names::read(vfs_tid);
    for i in 0..names.count {
        let Ok(list) = load(vfs_tid, names.get(i)) else { continue };
        let owns = lines(list).any(|l| matches!(l, Line::File(_, _, p) | Line::Link(p) if p == path));
        if owns {
            println!("{} is from {}", text(path), text(names.get(i)));
            syscall::sys_exit_code(0);
        }
    }
    println!("{} is from no package", text(path));
    syscall::sys_exit_code(1);
}

/// The checksum a list keeps of each file: the one zip and Ethernet use.
struct Crc {
    table: [u32; 256],
}

impl Crc {
    fn new() -> Crc {
        let mut table = [0u32; 256];
        for (i, slot) in table.iter_mut().enumerate() {
            let mut c = i as u32;
            for _ in 0..8 {
                c = if c & 1 != 0 { (c >> 1) ^ 0xEDB8_8320 } else { c >> 1 };
            }
            *slot = c;
        }
        Crc { table }
    }

    fn add(&self, crc: u32, bytes: &[u8]) -> u32 {
        bytes.iter().fold(crc, |c, &b| self.table[((c ^ b as u32) & 0xFF) as usize] ^ (c >> 8))
    }
}

/// A file's length and checksum, read from `root`.
fn measure(vfs_tid: usize, crc: &Crc, root: &[u8], path: &[u8]) -> Result<(u64, u32), u64> {
    let mut whole = [0u8; MAX_PATH];
    let whole = join(root, path, &mut whole).ok_or(vfs::ERR_NAME_TOO_LONG)?;
    let (handle, _, _) = vfs::open(vfs_tid, whole)?;
    let mut page = [0u8; 4096];
    let mut at = 0u64;
    let mut sum = !0u32;
    let result = loop {
        match vfs::read(vfs_tid, handle, &mut page, at as u32) {
            Ok(0) => break Ok((at, !sum)),
            Ok(n) => {
                sum = crc.add(sum, &page[..n as usize]);
                at += n as u64;
            }
            Err(code) => break Err(code),
        }
    };
    let _ = vfs::close(vfs_tid, handle);
    result
}

fn verify(vfs_tid: usize, first: usize) -> ! {
    let names = Names::read(vfs_tid);
    let crc = Crc::new();
    let wanted = |name: &[u8]| args::argc() <= first || (first..args::argc()).any(|i| args::argv(i) == Some(name));
    for i in first..args::argc() {
        let name = args::argv(i).unwrap_or(b"");
        if !(0..names.count).any(|n| names.get(n) == name) {
            fail(format_args!("there is no package called {}", text(name)));
        }
    }
    let mut wrong = 0;
    for i in 0..names.count {
        let name = names.get(i);
        if !wanted(name) {
            continue;
        }
        let Ok(list) = load(vfs_tid, name) else { continue };
        let (mut checked, mut bad) = (0, 0);
        for line in lines(list) {
            let Line::File(sum, size, path) = line else { continue };
            checked += 1;
            let said = match measure(vfs_tid, &crc, b"/", path) {
                Ok(found) if found == (size, sum) => continue,
                Ok(_) => "is not the file that was built",
                Err(vfs::ERR_NOT_FOUND) => "is missing",
                Err(_) => "cannot be read",
            };
            println!("  {} {}", text(path), said);
            bad += 1;
        }
        match bad {
            0 => println!("{}: {} files, as built", text(name), checked),
            n => println!("{}: {} of {} files are not as built", text(name), n, checked),
        }
        wrong += bad;
    }
    syscall::sys_exit_code(if wrong == 0 { 0 } else { 1 });
}

/// Make a directory and every one above it under `root`, each with the mode
/// the directory of that name has here.
fn make_dirs(vfs_tid: usize, root: &[u8], path: &[u8]) -> Result<(), u64> {
    let mut at = 0;
    loop {
        // The next slash past `at`, or the end.
        let end = path[at + 1..].iter().position(|&b| b == b'/').map_or(path.len(), |p| at + 1 + p);
        let prefix = &path[..end];
        let mut there = [0u8; MAX_PATH];
        let there = join(root, prefix, &mut there).ok_or(vfs::ERR_NAME_TOO_LONG)?;
        match vfs::mkdir(vfs_tid, there) {
            Ok(()) => {
                if let Ok(st) = vfs::lstat(vfs_tid, prefix) {
                    let which = vfs::ATTR_MODE | vfs::ATTR_UID | vfs::ATTR_GID;
                    let _ = vfs::set_attr(vfs_tid, there, which, st.mode & 0o7777, st.uid, st.gid, 0, 0);
                }
            }
            Err(vfs::ERR_EXISTS) => {}
            Err(code) => return Err(code),
        }
        if end == path.len() {
            return Ok(());
        }
        at = end;
    }
}

/// Copy the file or the link at `path` here to the same path under `root`.
fn copy(vfs_tid: usize, root: &[u8], path: &[u8]) -> Result<u64, u64> {
    let mut there = [0u8; MAX_PATH];
    let there = join(root, path, &mut there).ok_or(vfs::ERR_NAME_TOO_LONG)?;
    let from = vfs::open_with(vfs_tid, path, vfs::OPEN_NOFOLLOW)?;
    if from.mode & vfs::S_IFMT == vfs::S_IFLNK {
        let _ = vfs::close(vfs_tid, from.handle);
        let mut target = [0u8; MAX_PATH];
        let len = vfs::readlink(vfs_tid, path, &mut target)?.min(MAX_PATH);
        let _ = vfs::unlink(vfs_tid, there);
        return vfs::symlink(vfs_tid, &target[..len], there).map(|()| 0);
    }
    let copied = (|| {
        let st = vfs::stat_full(vfs_tid, from.handle)?;
        let to = vfs::open_with(vfs_tid, there, vfs::OPEN_CREATE | vfs::OPEN_TRUNCATE)?.handle;
        let mut page = [0u8; 4096];
        let mut at = 0u64;
        let moved = loop {
            let n = match vfs::read(vfs_tid, from.handle, &mut page, at as u32) {
                Ok(0) => break Ok(at),
                Ok(n) => n as usize,
                Err(code) => break Err(code),
            };
            let mut put = 0;
            let wrote = loop {
                if put == n {
                    break Ok(());
                }
                match vfs::write(vfs_tid, to, &page[put..n], (at + put as u64) as u32) {
                    Ok(0) => break Err(vfs::ERR_NO_SPACE),
                    Ok(w) => put += w as usize,
                    Err(code) => break Err(code),
                }
            };
            if let Err(code) = wrote {
                break Err(code);
            }
            at += n as u64;
        };
        let _ = vfs::close(vfs_tid, to);
        let size = moved?;
        // Whose it is, what may be done with it, and when it was last
        // changed: a program is a program by its mode, and a cache of fonts
        // is believed by its time.
        let which = vfs::ATTR_MODE | vfs::ATTR_UID | vfs::ATTR_GID | vfs::ATTR_ATIME | vfs::ATTR_MTIME;
        vfs::set_attr(vfs_tid, there, which, st.mode & 0o7777, st.uid, st.gid, st.atime, st.mtime)?;
        Ok(size)
    })();
    let _ = vfs::close(vfs_tid, from.handle);
    copied
}

fn strap(vfs_tid: usize) -> ! {
    let Some(root) = args::argv(2) else {
        println!("usage: qpkg strap ROOT SET...");
        syscall::sys_exit_code(2);
    };
    if args::argc() < 4 {
        println!("usage: qpkg strap ROOT SET...");
        println!("`qpkg sets` says what sets there are.");
        syscall::sys_exit_code(2);
    }
    match vfs::open_with(vfs_tid, root, vfs::OPEN_DIRECTORY) {
        Ok(o) => {
            let _ = vfs::close(vfs_tid, o.handle);
        }
        Err(_) => fail(format_args!("{} is not a directory: mount the new root there first", text(root))),
    }
    let mut same = [0u8; MAX_PATH];
    if matches!(
        (vfs::lstat(vfs_tid, root), vfs::lstat(vfs_tid, b"/")),
        (Ok(a), Ok(b)) if a.id == b.id
    ) || join(root, b"", &mut same).is_some_and(|r| r.is_empty())
    {
        fail(format_args!("{} is this system's own root", text(root)));
    }
    if syscall::sys_mmap(DIRS_AT, DIRS_PAGES).is_err() {
        fail(format_args!("no memory"));
    }
    let dirs = unsafe { core::slice::from_raw_parts_mut(DIRS_AT as *mut u8, DIRS_MAX) };
    let mut dirs_len = 0;

    let names = Names::read(vfs_tid);
    let in_set = |set: &[u8]| (3..args::argc()).any(|i| args::argv(i) == Some(set));
    // Every set asked for has to be one there is.
    for i in 3..args::argc() {
        let set = args::argv(i).unwrap_or(b"");
        let known = (0..names.count).any(|n| load(vfs_tid, names.get(n)).is_ok_and(|list| said(list, b"set") == set));
        if !known {
            fail(format_args!("there is no set called {}: `qpkg sets` says what there are", text(set)));
        }
    }

    let (mut packages, mut files, mut bytes) = (0, 0, 0u64);
    for i in 0..names.count {
        let name = names.get(i);
        let list = match load(vfs_tid, name) {
            Ok(list) if in_set(said(list, b"set")) => list,
            _ => continue,
        };
        let (count, size) = weight(list);
        print!("{:<12} {:>5} files {:>10}  ", text(name), count, Size(size));
        for line in lines(list) {
            let path = match line {
                Line::Dir(mode, path) => {
                    let mut there = [0u8; MAX_PATH];
                    let made = make_dirs(vfs_tid, root, path).and_then(|()| {
                        let there = join(root, path, &mut there).ok_or(vfs::ERR_NAME_TOO_LONG)?;
                        vfs::set_attr(vfs_tid, there, vfs::ATTR_MODE, mode, 0, 0, 0, 0)
                    });
                    if let Err(code) = made {
                        println!();
                        fail(format_args!("{} could not be made in {}: {}", text(path), text(root), why(code)));
                    }
                    continue;
                }
                Line::File(_, _, path) | Line::Link(path) => path,
                _ => continue,
            };
            let dir = match path.iter().rposition(|&b| b == b'/') {
                Some(0) | None => &b"/"[..],
                Some(at) => &path[..at],
            };
            // A new directory: made, and remembered for its times.
            let last = dirs[..dirs_len].rsplit(|&b| b == 0).nth(1).unwrap_or(b"");
            if last != dir {
                if let Err(code) = make_dirs(vfs_tid, root, dir) {
                    println!();
                    fail(format_args!("{} could not be made in {}: {}", text(dir), text(root), why(code)));
                }
                if dirs_len + dir.len() + 1 <= dirs.len() {
                    dirs[dirs_len..dirs_len + dir.len()].copy_from_slice(dir);
                    dirs[dirs_len + dir.len()] = 0;
                    dirs_len += dir.len() + 1;
                }
            }
            match copy(vfs_tid, root, path) {
                Ok(n) => {
                    files += 1;
                    bytes += n;
                }
                Err(code) => {
                    println!();
                    fail(format_args!("{} could not be copied to {}: {}", text(path), text(root), why(code)));
                }
            }
        }
        // And the list itself, so that the new system knows what it is made
        // of.
        let mut own = [0u8; MAX_PATH];
        let Some(own) = join(DB, name, &mut own) else { continue };
        if let Err(code) = make_dirs(vfs_tid, root, DB).and_then(|()| copy(vfs_tid, root, own)) {
            println!();
            fail(format_args!("the list of {} could not be copied: {}", text(name), why(code)));
        }
        println!("done");
        packages += 1;
    }

    // Each directory's times, now that nothing more will be put in it: a
    // cache that describes a directory is believed only while the directory
    // is no newer than it.
    for dir in dirs[..dirs_len].split(|&b| b == 0).filter(|d| !d.is_empty()) {
        let mut there = [0u8; MAX_PATH];
        if let (Ok(st), Some(there)) = (vfs::lstat(vfs_tid, dir), join(root, dir, &mut there)) {
            let _ = vfs::set_attr(vfs_tid, there, vfs::ATTR_ATIME | vfs::ATTR_MTIME, 0, 0, 0, st.atime, st.mtime);
        }
    }
    // A write is answered a moment before it is recorded for good, and what
    // this is about to say is that it has been.
    let _ = vfs::sync(vfs_tid);
    println!("{} packages, {} files, {} into {}", packages, files, Size(bytes), text(root));
    syscall::sys_exit_code(0);
}

fn usage() -> ! {
    println!("usage: qpkg                    the packages here");
    println!("       qpkg info NAME          what one is, and what its programs may do");
    println!("       qpkg files NAME         the files it owns");
    println!("       qpkg owner PATH         which package a file is from");
    println!("       qpkg verify [NAME...]   whether the files are still what was built");
    println!("       qpkg sets               the sets packages come in");
    println!("       qpkg strap ROOT SET...  put those sets' packages into another root");
    syscall::sys_exit_code(2);
}

#[unsafe(no_mangle)]
#[link_section = ".text.entry"]
pub extern "C" fn _start() -> ! {
    let Some(vfs_tid) = nameserver::lookup_retry(b"vfs", 20) else {
        fail(format_args!("there is no file server"));
    };
    if syscall::sys_mmap(RECORD_AT, RECORD_PAGES).is_err() {
        fail(format_args!("no memory"));
    }
    match (args::argv(1), args::argv(2), args::argv(3)) {
        (None, _, _) | (Some(b"list"), None, _) => list_all(vfs_tid),
        (Some(b"sets"), None, _) => sets(vfs_tid),
        (Some(b"info"), Some(name), None) => info(vfs_tid, name),
        (Some(b"files"), Some(name), None) => files(vfs_tid, name),
        (Some(b"owner"), Some(path), None) => owner(vfs_tid, path),
        (Some(b"verify"), _, _) => verify(vfs_tid, 2),
        (Some(b"strap"), _, _) => strap(vfs_tid),
        _ => usage(),
    }
}

#[panic_handler]
fn panic(info: &core::panic::PanicInfo) -> ! {
    println!("qpkg: {}", info);
    syscall::sys_exit_code(255);
}
