#![no_std]
#![no_main]

//! Run one command as somebody else.
//!
//! ```text
//! as USER COMMAND [ARGUMENT...]
//! ```
//!
//! `as root mount /dev/disk0p2 /mnt`. The command is started as USER, on
//! this terminal, where this was, with what USER's sessions hold; this
//! waits for it and ends as it ended.
//!
//! Whose password is asked for is what an account's rights decide. An
//! account that may `become` is asked for **its own**: the right is the
//! account's, and the password says only that it is that account's owner
//! typing. One that may not is asked for USER's, as `su` asks. Root is asked
//! nothing.
//!
//! Like `su`, this holds nothing that could make anybody anybody. It builds
//! the command and asks `auth` to say whose it is.

use quark_rt::accounts::{self, Rights};
use quark_rt::auth;
use quark_rt::nameserver;
use quark_rt::session::{self, Refused, Session};
use quark_rt::spawn::Scratch;
use quark_rt::stdio::read_secret;
use quark_rt::{args, print, println, syscall, vfs};

const FILE_BUF_BASE: usize = 0x94_0000_0000;
const SPAWN_SCRATCH: Scratch = Scratch { elf: 0x95_0000_0000, stack: 0x96_0000_0000, args: 0x97_0000_0000 };
const TEXT_AT: usize = 0x98_0000_0000;
const TEXT_PAGES: usize = 8;
/// The most words a command may have, its name included.
const MAX_WORDS: usize = 16;

fn fail(what: core::fmt::Arguments) -> ! {
    println!("as: {}", what);
    syscall::sys_exit_code(1);
}

fn text(bytes: &[u8]) -> &str {
    core::str::from_utf8(bytes).unwrap_or("?")
}

/// Where a command is: as given if it names a path, in `/usr/bin` if not,
/// and there under either of the names a program may have.
fn find<'a>(vfs_tid: usize, command: &[u8], out: &'a mut [u8; 128]) -> Option<&'a [u8]> {
    let there = |path: &[u8]| vfs::open(vfs_tid, path).map(|(h, _, dir)| (vfs::close(vfs_tid, h), dir)).is_ok_and(|(_, dir)| !dir);
    if command.contains(&b'/') {
        return (command.len() <= out.len() && there(command)).then(|| {
            out[..command.len()].copy_from_slice(command);
            &out[..command.len()]
        });
    }
    let dir = b"/usr/bin/";
    let n = dir.len() + command.len();
    if n + 4 > out.len() {
        return None;
    }
    out[..dir.len()].copy_from_slice(dir);
    out[dir.len()..n].copy_from_slice(command);
    if there(&out[..n]) {
        return Some(&out[..n]);
    }
    out[dir.len()..n].make_ascii_uppercase();
    out[n..n + 4].copy_from_slice(b".ELF");
    there(&out[..n + 4]).then_some(&out[..n + 4])
}

#[unsafe(no_mangle)]
#[link_section = ".text.entry"]
pub extern "C" fn _start() -> ! {
    let (Some(name), Some(command)) = (args::argv(1), args::argv(2)) else {
        println!("usage: as USER COMMAND [ARGUMENT...]");
        syscall::sys_exit_code(2);
    };
    if args::argc() - 2 > MAX_WORDS {
        fail(format_args!("that is more words than a command may have"));
    }
    let Some(vfs_tid) = nameserver::lookup_retry(b"vfs", 20) else {
        fail(format_args!("there is no file server"));
    };
    if syscall::sys_mmap(TEXT_AT, TEXT_PAGES).is_err() {
        fail(format_args!("no memory"));
    }
    let pages = unsafe { core::slice::from_raw_parts_mut(TEXT_AT as *mut u8, TEXT_PAGES * 4096) };
    let (passwd_buf, rights_buf) = pages.split_at_mut(4 * 4096);
    let Some(passwd) = accounts::read(vfs_tid, b"", b"passwd", passwd_buf) else {
        fail(format_args!("/etc/passwd cannot be read"));
    };
    let Some(user) = accounts::user_named(passwd, name) else {
        fail(format_args!("there is no user called {}", text(name)));
    };
    let mut path = [0u8; 128];
    let Some(program) = find(vfs_tid, command, &mut path) else {
        fail(format_args!("{}: not found", text(command)));
    };

    // Whose password, if anybody's.
    let (me, _) = syscall::sys_get_uid();
    let mine = accounts::user_numbered(passwd, me);
    let rights = accounts::read(vfs_tid, b"", b"rights", rights_buf);
    let own = mine.is_some_and(|m| accounts::rights_of(rights, m.name, m.uid).has(Rights::BECOME));
    let mut password = [0u8; quark_rt::crypt::MAX_PASSWORD + 2];
    let mut typed = 0;
    if me != 0 {
        let whose = if own { mine.map_or(name, |m| m.name) } else { name };
        match auth::needs(whose) {
            Ok(false) => {}
            Ok(true) => {
                print!("{}'s password: ", text(whose));
                typed = read_secret(&mut password);
                while typed > 0 && matches!(password[typed - 1], b'\n' | b'\r') {
                    typed -= 1;
                }
            }
            Err(code) => fail(format_args!("{}", auth::why(code))),
        }
    }

    let mut argv: [&[u8]; MAX_WORDS] = [b""; MAX_WORDS];
    let argc = args::argc() - 2;
    for (i, slot) in argv.iter_mut().take(argc).enumerate() {
        *slot = args::argv(i + 2).unwrap_or(b"");
    }
    // Whose it is, for a program that asks its environment.
    let mut vars = [[0u8; 80]; 3];
    let mut lens = [0usize; 3];
    for (i, (key, value)) in
        [(&b"HOME="[..], user.home), (&b"USER="[..], user.name), (&b"LOGNAME="[..], user.name)].iter().enumerate()
    {
        let v = &value[..value.len().min(80 - key.len())];
        vars[i][..key.len()].copy_from_slice(key);
        vars[i][key.len()..key.len() + v.len()].copy_from_slice(v);
        lens[i] = key.len() + v.len();
    }
    let term: &[u8] = if syscall::sys_pty_number(0).is_ok() { b"TERM=linux" } else { b"TERM=dumb" };
    let env: [&[u8]; 5] = [
        &vars[0][..lens[0]],
        &vars[1][..lens[1]],
        &vars[2][..lens[2]],
        b"PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        term,
    ];
    let begun = session::prepare(
        vfs_tid,
        &Session {
            user: &user,
            password: &password[..typed],
            flags: if own && me != 0 { auth::OWN } else { 0 },
            program,
            args: &argv[..argc],
            env: &env,
            home: false,
        },
        FILE_BUF_BASE,
        &SPAWN_SCRATCH,
    );
    password.fill(0);
    let info = match begun {
        Ok(info) => info,
        Err(Refused::NoProgram) => fail(format_args!("{} will not load", text(program))),
        Err(Refused::Auth(auth::ERR_WRONG)) => fail(format_args!("that is not the password")),
        Err(Refused::Auth(auth::ERR_NOT_ALLOWED)) => {
            fail(format_args!("this account may not become another: `user NAME may become` is how it is given"))
        }
        Err(Refused::Auth(code)) => fail(format_args!("{}", auth::why(code))),
    };

    // What is typed at the terminal is for the command now, not for this.
    let _ = syscall::sys_sig_action(syscall::SIGINT, syscall::SIG_IGNORE);
    let _ = syscall::sys_sig_action(syscall::SIGQUIT, syscall::SIG_IGNORE);
    let tid = info.tid;
    if info.start().is_err() {
        info.discard();
        fail(format_args!("{} would not start", text(command)));
    }
    let status = loop {
        match syscall::sys_wait() {
            Ok((t, code)) if t == tid => break code,
            Ok(_) => continue,
            Err(()) => break 1,
        }
    };
    if let Some(group) = syscall::sys_getpgid(0) {
        let _ = syscall::sys_pty_set_front(0, group, true);
    }
    syscall::sys_exit_code(if status < 0 { 128 - status } else { status });
}

#[panic_handler]
fn panic(info: &core::panic::PanicInfo) -> ! {
    println!("as: {}", info);
    syscall::sys_exit_code(255);
}
