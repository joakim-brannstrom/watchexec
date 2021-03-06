# watchexec

**watchexec** is a simple, standalone program that watches a path for changes
and runs a command when it detects any modifications.

## Features

* simple invocation and use
* monitors one or more root directories recursively for changes
* support watching only files with specific file extensions
* automatically uses ignores from `.gitignore`
    * if it doesn't exists then default ignores are used if not instructed to do otherwise
* optionally send a desktop notification with the exit code from the command
    * requires that the command `notify-send` is installed
* optionally clears the screen between executing the command
* optinally restart the command if it is already executing when a modification is detected
* optionally watch for metadata changes.
* sandbox feature which mean that when a process is terminated it also mean that all its children are killed
* sets the following environment variables in the child process when `--env` is used:
    * `$WATCHEXEC_EVENT` is a tuple of values "event type":"path"
    * If multiple files changed then the events are separated by ";"

## Usage Examples

A generic project that must first build the program before the test suite can execute.

    $ watchexec -w src --shell -- "make all && make test"

If you are a D developer that wants to execute your tests.

    $ watchexech -w source -- dub test

# Getting Started

watchexec depends on the following software packages:

 * [D compiler](https://dlang.org/download.html) (dmd 2.079+, ldc 1.11.0+)

It is recommended to install the D compiler by downloading it from the official distribution page.
```sh
# link https://dlang.org/download.html
curl -fsS https://dlang.org/install.sh | bash -s dmd
```

Then you can run watchexec via dub:
```sh
dub run watchexec
```

alternatively you can clone the repo and build it yourself.
```sh
git clone https://github.com/joakim-brannstrom/watchexec.git
cd watchexec
dub build -b release
```

Done! Have fun.
Don't be shy to report any issue that you find.

# Credit

This is a basically a re-implementation of
[watchexec](git@github.com:watchexec/watchexec.git). I had for a long time been
using inotifywait in custom bash scripts but the rust version of watchexec
where actually better.
