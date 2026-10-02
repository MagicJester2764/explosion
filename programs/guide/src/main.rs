#![no_std]
#![no_main]

//! The installation guide, a section at a time.
//!
//! ```text
//! guide          what the sections are
//! guide N        section N
//! guide all      the whole of it
//! ```
//!
//! The guide is `/usr/share/doc/explosion/install.md`, the same file the
//! distribution keeps as `docs/install.md`. A section is what follows a
//! line beginning `## `, and each is kept short enough to read on a console
//! that does not scroll back: there is nothing to page.

use quark_rt::{args, nameserver, println, syscall, vfs};

const GUIDE: &[u8] = b"/usr/share/doc/explosion/install.md";
const TEXT_AT: usize = 0x9A_0000_0000;
const TEXT_PAGES: usize = 16;

fn text(bytes: &[u8]) -> &str {
    core::str::from_utf8(bytes).unwrap_or("?")
}

/// A line as the console shows it: the marks that make a web page of the
/// file are not for reading.
fn show(line: &[u8]) {
    if line.starts_with(b"```") {
        return;
    }
    println!("{}", text(line));
}

#[unsafe(no_mangle)]
#[link_section = ".text.entry"]
pub extern "C" fn _start() -> ! {
    let vfs_tid = nameserver::lookup_retry(b"vfs", 20).unwrap_or(0);
    let room = TEXT_PAGES * 4096;
    if syscall::sys_mmap(TEXT_AT, TEXT_PAGES).is_err() {
        println!("guide: no memory");
        syscall::sys_exit_code(1);
    }
    let buf = unsafe { core::slice::from_raw_parts_mut(TEXT_AT as *mut u8, room) };
    let mut len = 0;
    match vfs::open(vfs_tid, GUIDE) {
        Ok((handle, _, false)) => {
            while len < room {
                match vfs::read(vfs_tid, handle, &mut buf[len..], len as u32) {
                    Ok(n) if n > 0 => len += n as usize,
                    _ => break,
                }
            }
            let _ = vfs::close(vfs_tid, handle);
        }
        _ => {
            println!("guide: there is no {} here", text(GUIDE));
            syscall::sys_exit_code(1);
        }
    }
    let guide = &buf[..len];
    let sections = || guide.split(|&b| b == b'\n').filter(|l| l.starts_with(b"## "));

    match (args::argv(1), args::argv(2)) {
        (None, _) => {
            // Everything before the first section is what the guide is.
            for line in guide.split(|&b| b == b'\n').take_while(|l| !l.starts_with(b"## ")) {
                show(line.strip_prefix(b"# ").unwrap_or(line));
            }
            for (n, title) in sections().enumerate() {
                println!("  {:>2}  {}", n + 1, text(&title[3..]));
            }
            println!();
            println!("`guide 1` shows the first of them, and `guide all` every one.");
        }
        (Some(b"all"), None) => {
            for line in guide.split(|&b| b == b'\n') {
                show(line);
            }
        }
        (Some(word), None) => {
            let wanted = word
                .iter()
                .try_fold(0usize, |n, &c| {
                    c.is_ascii_digit().then_some(())?;
                    n.checked_mul(10)?.checked_add((c - b'0') as usize)
                })
                .filter(|&n| n >= 1 && n <= sections().count());
            let Some(wanted) = wanted else {
                println!("guide: there are sections 1 to {}", sections().count());
                syscall::sys_exit_code(1);
            };
            let mut at = 0;
            for line in guide.split(|&b| b == b'\n') {
                if line.starts_with(b"## ") {
                    at += 1;
                    if at == wanted {
                        println!("{}. {}", at, text(&line[3..]));
                        continue;
                    }
                }
                if at == wanted {
                    show(line);
                }
            }
            if wanted < sections().count() {
                println!("`guide {}` is next.", wanted + 1);
            }
        }
        _ => {
            println!("usage: guide [N | all]");
            syscall::sys_exit_code(2);
        }
    }
    syscall::sys_exit_code(0);
}

#[panic_handler]
fn panic(info: &core::panic::PanicInfo) -> ! {
    println!("guide: {}", info);
    syscall::sys_exit_code(255);
}
