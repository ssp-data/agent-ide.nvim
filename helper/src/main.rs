use agent_ide_helper::protocol::{Out, Server};
use std::path::PathBuf;

fn main() {
    let mut cache_dir: Option<PathBuf> = None;
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--cache-dir" => match args.next() {
                Some(d) => cache_dir = Some(PathBuf::from(d)),
                None => usage(),
            },
            _ => usage(),
        }
    }
    let mut server = Server::new(cache_dir, Out::stdout());
    server.run(std::io::stdin().lock());
}

fn usage() -> ! {
    eprintln!("usage: agent-ide-helper [--cache-dir <dir>]");
    std::process::exit(2);
}
