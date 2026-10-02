#![no_std]
#![no_main]

//! Who there is on this system, and what each of them may do.
//!
//! ```text
//! user                              everybody, and what each may do
//! user add NAME                     a new user, with a home of their own
//! user remove NAME                  take one away (the home is left)
//! user NAME may RIGHT...            give rights
//! user NAME may not RIGHT...        take them back
//! ```
//!
//! With `--root DIR` first, all of it is about a system mounted at DIR:
//! how an installer makes the first user of one.
//!
//! An account here is two things. It is who somebody is — a name, a number,
//! a home — which decides whose files are whose. And it is what its
//! sessions may *hold*, which on this system is the rest of what "root"
//! means anywhere else:
//!
//! - `power`: turn the machine off, and restart it.
//! - `tasks`: end any program, whoever's.
//! - `become`: run a command as another user with one's own password (`as`).
//!
//! They are kept in `/etc/rights` and handed to a session when it begins,
//! as capabilities: a right taken back is gone from the next login. Root
//! has all of them unless a line says otherwise.

use quark_rt::accounts::{self, NewUser, Rights};
use quark_rt::nameserver;
use quark_rt::{args, print, println, syscall};

const WORK_AT: usize = 0x98_0000_0000;
/// The account files, and one more for the rights.
const PAGES: usize = accounts::WORK / 4096 + 4;

fn text(bytes: &[u8]) -> &str {
    core::str::from_utf8(bytes).unwrap_or("?")
}

fn usage() -> ! {
    println!("usage: user [--root DIR]                        everybody, and what each may do");
    println!("       user [--root DIR] add NAME               a new user");
    println!("       user [--root DIR] remove NAME            take one away");
    println!("       user [--root DIR] NAME may RIGHT...      power, tasks, become");
    println!("       user [--root DIR] NAME may not RIGHT...");
    syscall::sys_exit_code(2);
}

fn fail(what: core::fmt::Arguments) -> ! {
    println!("user: {}", what);
    syscall::sys_exit_code(1);
}

/// The rights in `r`, as words with commas between.
fn show(r: Rights) {
    if r.has(Rights::ALL) {
        print!("everything");
        return;
    }
    let mut any = false;
    for (name, bit) in accounts::RIGHT_NAMES {
        if bit != Rights::ALL && r.has(bit) {
            print!("{}{}", if any { ", " } else { "" }, text(name));
            any = true;
        }
    }
    if !any {
        print!("-");
    }
}

#[unsafe(no_mangle)]
#[link_section = ".text.entry"]
pub extern "C" fn _start() -> ! {
    let mut words: [&[u8]; 12] = [b""; 12];
    let mut n = 0;
    let mut root: &[u8] = b"";
    let mut i = 1;
    while let Some(arg) = args::argv(i) {
        if arg == b"--root" || arg == b"-R" {
            i += 1;
            root = args::argv(i).unwrap_or_else(|| usage());
        } else if arg.starts_with(b"-") || n == words.len() {
            usage();
        } else {
            words[n] = arg;
            n += 1;
        }
        i += 1;
    }
    let words = &words[..n];

    let Some(vfs_tid) = nameserver::lookup_retry(b"vfs", 20) else {
        fail(format_args!("there is no file server"));
    };
    if syscall::sys_mmap(WORK_AT, PAGES).is_err() {
        fail(format_args!("no memory"));
    }
    let all = unsafe { core::slice::from_raw_parts_mut(WORK_AT as *mut u8, PAGES * 4096) };
    let (work, rights_buf) = all.split_at_mut(accounts::WORK);
    let (rights_buf, out) = rights_buf.split_at_mut(2 * 4096);

    match words {
        [] => {
            let (passwd_buf, _) = work.split_at_mut(accounts::WORK / 5);
            let Some(passwd) = accounts::read(vfs_tid, root, b"passwd", passwd_buf) else {
                fail(format_args!("the accounts cannot be read"));
            };
            let rights = accounts::read(vfs_tid, root, b"rights", rights_buf);
            println!("{:<12} {:>6}  {:<20} MAY", "NAME", "ID", "HOME");
            for user in accounts::users(passwd) {
                print!("{:<12} {:>6}  {:<20} ", text(user.name), user.uid, text(user.home));
                show(accounts::rights_of(rights, user.name, user.uid));
                println!();
            }
        }
        [b"add", name] => {
            let new = NewUser { name, uid: None, group: None, about: b"", home: None, shell: None, make_home: true };
            match accounts::add_user(vfs_tid, root, &new, work) {
                Ok((uid, _)) => {
                    println!("{} is user {}, with a home at /home/{}.", text(name), uid, text(name));
                    println!("Nobody logs in as {} until it has a password: `passwd{} {}`.",
                        text(name),
                        if root.is_empty() { "" } else { " --root DIR" },
                        text(name));
                }
                Err(trouble) => fail(format_args!("{}: {}", text(name), trouble.words())),
            }
        }
        [b"remove", name] => match accounts::remove_user(vfs_tid, root, name, work) {
            Ok(()) => {
                // And what it was allowed, so that a later user of the name
                // does not find it waiting.
                if let Some(rights) = accounts::read(vfs_tid, root, b"rights", rights_buf) {
                    if let Some(len) = accounts::with_record(rights, name, b' ', None, out) {
                        let _ = accounts::write(vfs_tid, root, b"rights", &out[..len], 0o644);
                    }
                }
                println!("{} is gone. Its home is where it was.", text(name));
            }
            Err(accounts::Trouble::Taken) => fail(format_args!("{} is the one user a system cannot be without", text(name))),
            Err(trouble) => fail(format_args!("{}: {}", text(name), trouble.words())),
        },
        [name, b"may", rest @ ..] if !rest.is_empty() => {
            let (giving, named) = match rest {
                [b"not", named @ ..] if !named.is_empty() => (false, named),
                named => (true, named),
            };
            let (passwd_buf, _) = work.split_at_mut(accounts::WORK / 5);
            let Some(user) = accounts::read(vfs_tid, root, b"passwd", passwd_buf).and_then(|p| accounts::user_named(p, name))
            else {
                fail(format_args!("there is no user called {}", text(name)));
            };
            let rights = accounts::read(vfs_tid, root, b"rights", rights_buf);
            let mut now = accounts::rights_of(rights, user.name, user.uid).0;
            for word in named {
                let Some(bit) = Rights::named(word) else {
                    fail(format_args!("{} is not a right: there are power, tasks, become and all", text(word)));
                };
                now = if giving { now | bit } else { now & !bit };
            }
            // The line: the name, and each right it has now.
            let mut line = [0u8; 128];
            let mut len = 0;
            let mut put = |bytes: &[u8]| {
                line[len..len + bytes.len()].copy_from_slice(bytes);
                len += bytes.len();
            };
            put(user.name);
            if Rights(now).has(Rights::ALL) {
                put(b" all");
            } else {
                for (word, bit) in accounts::RIGHT_NAMES {
                    if bit != Rights::ALL && now & bit == bit {
                        put(b" ");
                        put(word);
                    }
                }
            }
            let Some(out_len) = accounts::with_record(rights.unwrap_or(b""), user.name, b' ', Some(&line[..len]), out)
            else {
                fail(format_args!("/etc/rights has no room for it"));
            };
            match accounts::write(vfs_tid, root, b"rights", &out[..out_len], 0o644) {
                Ok(()) => {
                    print!("{} may: ", text(user.name));
                    show(Rights(now));
                    println!(". From their next login.");
                }
                Err(code) => fail(format_args!("/etc/rights: {}", quark_rt::vfs::why(code))),
            }
        }
        _ => usage(),
    }
    syscall::sys_exit_code(0);
}

#[panic_handler]
fn panic(info: &core::panic::PanicInfo) -> ! {
    println!("user: {}", info);
    syscall::sys_exit_code(255);
}
