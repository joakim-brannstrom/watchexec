/**
Copyright: Copyright (c) 2020, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module watchexec;

import core.thread : Thread;
import logger = std.experimental.logger;
import std.algorithm : filter, map, joiner;
import std.array : array, empty;
import std.conv : text;
import std.datetime : Duration;
import std.datetime : dur, Clock;
import std.exception : collectException;
import std.format : format;

import colorlog;
import my.filter;
import my.path;

version (unittest) {
} else {
    int main(string[] args) {
        confLogger(VerboseMode.info);

        auto conf = parseUserArgs(args);

        confLogger(conf.global.verbosity);
        logger.trace(conf);

        if (conf.global.help)
            return cliHelp(conf);
        return cli(conf);
    }
}

private:

immutable notifySendCmd = "notify-send";

immutable defaultExclude = [
    "*/.DS_Store", "*.py[co]", "*/#*#", "*/.#*", "*/.*.kate-swp", "*/.*.sw?",
    "*/.*.sw?x", "*/.git/*"
];

int cliHelp(AppConfig conf) {
    conf.printHelp;
    return 0;
}

int cli(AppConfig conf) {
    import std.stdio : write, writeln;
    import my.fswatch : ContentEvents, MetadataEvents;
    import proc;

    if (conf.global.paths.empty) {
        logger.error("No directories specified to watch");
        return 1;
    }
    if (conf.global.command.empty) {
        logger.error("No command to execute specified");
        return 1;
    }

    logger.infof("command to execute on change: %-(%s %)", conf.global.command);
    logger.infof("watching for change: %s", conf.global.paths);

    const cmd = () {
        if (conf.global.useShell)
            return ["/bin/sh", "-c"] ~ format!"%-(%s %)"(conf.global.command);
        return conf.global.command;
    }();

    auto monitor = Monitor(conf.global.paths, GlobFilter(conf.global.include,
            conf.global.exclude), conf.global.watchMetadata
            ? (ContentEvents | MetadataEvents) : ContentEvents);

    MonitorResult[] eventFiles;
    auto handleExitStatus = HandleExitStatus(conf.global.useNotifySend, conf.global.paths);

    while (true) {
        if (eventFiles.empty) {
            eventFiles = monitor.wait(1000.dur!"weeks");
        }

        foreach (changed; eventFiles) {
            logger.tracef("%s changed", changed);
        }

        if (!eventFiles.empty) {
            string[string] env;

            if (conf.global.setEnv) {
                env["WATCHEXEC_EVENT"] = eventFiles.map!(a => format!"%s:%s"(a.kind,
                        a.path)).joiner(";").text;
            }

            eventFiles = null;

            if (conf.global.debounce != Duration.zero) {
                Thread.sleep(conf.global.debounce);
            }

            if (conf.global.clearScreen) {
                write("\033c");
            }

            try {
                auto p = spawnProcess(cmd, env).sandbox.timeout(conf.global.timeout).rcKill;

                if (conf.global.restart) {
                    while (!p.tryWait && eventFiles.empty) {
                        eventFiles = monitor.wait(10.dur!"msecs");
                    }

                    if (eventFiles.empty) {
                        handleExitStatus.exitStatus(p.status);
                    } else {
                        p.kill;
                        p.wait;
                    }
                } else {
                    p.wait;
                    handleExitStatus.exitStatus(p.status);
                }
                monitor.clear;
            } catch (Exception e) {
                logger.error(e.msg);
                return 1;
            }

        }
    }
}

struct HandleExitStatus {
    AbsolutePath[] roots;
    bool useNotifySend;

    this(bool useNotifySend, AbsolutePath[] roots) {
        this.useNotifySend = useNotifySend;
        this.roots = roots;
    }

    void exitStatus(int code) {
        import std.conv : to;
        import std.process : spawnProcess, wait;

        immutable msgExitStatus = "exit status";
        immutable msgOk = "✓";
        immutable msgNok = "✗";

        if (useNotifySend) {
            auto msg = () {
                if (code == 0)
                    return format!"%s %s %s\n%-(%s\n%)"(msgOk, msgExitStatus, code, roots);
                return format!"%s %s %s\n%-(%s\n%)"(msgNok, msgExitStatus, code, roots);
            }();

            spawnProcess([
                    notifySendCmd, "-u", "normal", "-t", "3000", "-a", "watchexec",
                    msg
                    ]).wait;
        }

        auto msg = () {
            if (code == 0)
                return format!"%s %s"(msgOk, msgExitStatus.color(Color.green));
            return format!"%s %s"(msgNok, msgExitStatus.color(Color.red));
        }();

        logger.infof("%s %s", msg, code);
    }
}

struct AppConfig {
    static import std.getopt;

    static struct Global {
        std.getopt.GetoptResult helpInfo;
        VerboseMode verbosity;
        bool help = true;

        AbsolutePath[] paths;
        Duration debounce;
        Duration timeout;
        bool clearScreen;
        bool restart;
        bool setEnv;
        bool useNotifySend;
        bool useShell;
        bool watchMetadata;
        string progName;
        string[] command;

        string[] include;
        string[] exclude;
    }

    Global global;

    void printHelp() {
        std.getopt.defaultGetoptPrinter(format(
                "Execute commands when watched files change\nusage: %s [options] -- <command>\n\noptions:",
                global.progName), global.helpInfo.options);
    }
}

AppConfig parseUserArgs(string[] args) {
    import logger = std.experimental.logger;
    import std.algorithm : countUntil, map;
    import std.path : baseName;
    import std.traits : EnumMembers;
    import my.file : existsAnd, isFile, whichFromEnv;
    static import std.getopt;

    AppConfig conf;
    conf.global.progName = args[0].baseName;

    try {
        const idx = countUntil(args, "--");
        if (args.length > 1 && idx > 1) {
            conf.global.command = args[idx + 1 .. $];
            args = args[0 .. idx];
        }

        bool noDefaultIgnore;
        bool noVcsIgnore;
        string[] include;
        string[] monitorExtensions;
        string[] paths;
        uint debounce = 200;
        uint timeout = 3600;
        // dfmt off
        conf.global.helpInfo = std.getopt.getopt(args,
            "c|clear", "clear screen before executing command",&conf.global.clearScreen,
            "d|debounce", format!"set the timeout between detected change and command execution (default: %sms)"(debounce), &debounce,
            "env", "set WATCHEXEC_*_PATH environment variables when executing the command", &conf.global.setEnv,
            "exclude", "ignore modifications to paths matching the pattern (glob: <empty>)", &conf.global.exclude,
            "e|ext", "file extensions, excluding dot, to watch (default: any)", &monitorExtensions,
            "include", "ignore all modifications except those matching the pattern (glob: *)", &conf.global.include,
            "meta", "watch for metadata changes (date, open/close, permission)", &conf.global.watchMetadata,
            "no-default-ignore", "skip auto-ignoring of commonly ignored globs", &noDefaultIgnore,
            "no-vcs-ignore", "skip auto-loading of .gitignore files for filtering", &noVcsIgnore,
            "notify", format!"use %s for desktop notification with commands exit status"(notifySendCmd), &conf.global.useNotifySend,
            "r|restart", "restart the process if it's still running", &conf.global.restart,
            "shell", "run the command in a shell (/bin/sh)", &conf.global.useShell,
            "t|timeout", format!"max runtime of the command (default: %ss)"(timeout), &timeout,
            "v|verbose", format("Set the verbosity (%-(%s, %))", [EnumMembers!(VerboseMode)]), &conf.global.verbosity,
            "w|watch", "watch a specific directory", &paths,
            );
        // dfmt on

        include ~= monitorExtensions.map!(a => format!"*.%s"(a)).array;
        if (include.empty) {
            conf.global.include = ["*"];
        } else {
            conf.global.include = include;
        }

        if (!noVcsIgnore && existsAnd!isFile(Path(".gitignore"))) {
            import std.file : readText;

            try {
                conf.global.exclude ~= parseGitIgnore(readText(".gitignore"));
            } catch (Exception e) {
                logger.warning(e.msg);
            }
        } else if (!noDefaultIgnore) {
            conf.global.exclude ~= defaultExclude;
        }

        if (conf.global.useNotifySend) {
            if (!whichFromEnv("PATH", notifySendCmd)) {
                conf.global.useNotifySend = false;
                logger.warningf("--notify requires the command %s", notifySendCmd);
            }
        }

        conf.global.timeout = timeout.dur!"seconds";
        conf.global.debounce = debounce.dur!"msecs";
        conf.global.paths = paths.map!(a => AbsolutePath(a)).array;

        conf.global.help = conf.global.helpInfo.helpWanted;
    } catch (std.getopt.GetOptException e) {
        // unknown option
        logger.error(e.msg);
    } catch (Exception e) {
        logger.error(e.msg);
    }

    return conf;
}

struct MonitorResult {
    enum Kind {
        Access,
        Attribute,
        CloseWrite,
        CloseNoWrite,
        Create,
        Delete,
        DeleteSelf,
        Modify,
        MoveSelf,
        Rename,
        Open,
    }

    Kind kind;
    AbsolutePath path;
}

/** Monitor root's for filesystem changes which create/remove/modify
 * files/directories.
 */
struct Monitor {
    import std.algorithm : canFind;
    import std.array : appender;
    import std.file : isDir;
    import std.utf : UTFException;
    import my.fswatch;
    import sumtype;

    AbsolutePath[] roots;
    FileWatch fw;
    GlobFilter fileFilter;
    uint events;

    /**
     * Params:
     *  roots = directories to recursively monitor
     */
    this(AbsolutePath[] roots, GlobFilter fileFilter, uint events = ContentEvents) {
        this.roots = roots;
        this.fileFilter = fileFilter;
        this.events = events;

        auto app = appender!(AbsolutePath[])();
        fw = fileWatch();
        foreach (r; roots) {
            app.put(fw.watchRecurse!(a => isInteresting(fileFilter, a))(r, events));
        }

        logger.trace(!app.data.empty, "unable to watch ", app.data);
    }

    static bool isInteresting(GlobFilter fileFilter, string p) nothrow {
        import my.file;

        try {
            const ap = AbsolutePath(p);

            if (existsAnd!isDir(ap)) {
                return true;
            }
            return fileFilter.match(ap);
        } catch (Exception e) {
            collectException(logger.trace(e.msg));
        }

        return false;
    }

    MonitorResult[] wait(Duration timeout) {
        import std.algorithm : canFind, startsWith;

        auto rval = appender!(MonitorResult[])();
        try {
            foreach (e; fw.getEvents(timeout)) {
                e.match!((Event.Access x) {
                    rval.put(MonitorResult(MonitorResult.Kind.Access, x.path));
                }, (Event.Attribute x) {
                    rval.put(MonitorResult(MonitorResult.Kind.Attribute, x.path));
                }, (Event.CloseWrite x) {
                    rval.put(MonitorResult(MonitorResult.Kind.CloseWrite, x.path));
                }, (Event.CloseNoWrite x) {
                    rval.put(MonitorResult(MonitorResult.Kind.CloseNoWrite, x.path));
                }, (Event.Create x) {
                    rval.put(MonitorResult(MonitorResult.Kind.Create, x.path));
                    fw.watchRecurse!(a => isInteresting(fileFilter, a))(x.path, events);
                }, (Event.Modify x) {
                    rval.put(MonitorResult(MonitorResult.Kind.Modify, x.path));
                }, (Event.MoveSelf x) {
                    rval.put(MonitorResult(MonitorResult.Kind.MoveSelf, x.path));
                    if (canFind!((a, b) => b.toString.startsWith(a.toString) != 0)(roots, x.path)) {
                        fw.watchRecurse!(a => isInteresting(fileFilter, a))(x.path, events);
                    }
                }, (Event.Delete x) {
                    rval.put(MonitorResult(MonitorResult.Kind.Delete, x.path));
                }, (Event.DeleteSelf x) {
                    rval.put(MonitorResult(MonitorResult.Kind.DeleteSelf, x.path));
                }, (Event.Rename x) {
                    rval.put(MonitorResult(MonitorResult.Kind.Rename, x.to));
                }, (Event.Open x) {
                    rval.put(MonitorResult(MonitorResult.Kind.Open, x.path));
                },);
            }
        } catch (UTFException e) {
            logger.warning(e.msg);
            logger.info("Maybe it works if you use the flag --shell?");
        }

        return rval.data.filter!(a => fileFilter.match(a.path)).array;
    }

    /// Clear the event listener of any residual events.
    void clear() {
        foreach (e; fw.getEvents(Duration.zero)) {
            e.match!((Event.Access x) {}, (Event.Attribute x) {}, (Event.CloseWrite x) {
            }, (Event.CloseNoWrite x) {}, (Event.Create x) {
                // add any new files/directories to be listened on
                fw.watchRecurse!(a => isInteresting(fileFilter, a))(x.path, events);
            }, (Event.Modify x) {}, (Event.MoveSelf x) {}, (Event.Delete x) {}, (Event.DeleteSelf x) {
            }, (Event.Rename x) {}, (Event.Open x) {},);
        }

        fw.getEvents;
    }
}

/** Filter strings by first cutting out a region (include) and then selectively
 * remove (exclude) from that region.
 *
 * I often use this in my programs to allow a user to specify what files to
 * process and the have some control over what to exclude.
 */
struct GlobFilter {
    string[] include;
    string[] exclude;

    /**
     * The regular expressions are set to ignoring the case.
     *
     * Params:
     *  include = glob string patter
     *  exclude = glob string patterh
     */
    this(string[] include, string[] exclude) {
        this.include = include;
        this.exclude = exclude;
    }

    /**
     * Returns: true if `s` matches `ìncludeRe` and NOT matches any of `excludeRe`.
     */
    bool match(string s) {
        import std.algorithm : canFind;
        import std.path : globMatch;

        if (!canFind!((a, b) => globMatch(b, a))(include, s)) {
            debug logger.tracef("%s did not match any of %s", s, include);
            return false;
        }

        if (canFind!((a, b) => globMatch(b, a))(exclude, s)) {
            debug logger.tracef("%s did match one of %s", s, exclude);
            return false;
        }

        return true;
    }
}

/** Returns: the glob patterns from `content`.
 *
 * The syntax is the one found in .gitignore files.
 */
string[] parseGitIgnore(string content) {
    import std.algorithm : splitter;
    import std.array : appender;
    import std.ascii : newline;
    import std.string : strip;

    auto app = appender!(string[])();

    foreach (l; content.splitter(newline).filter!(a => !a.empty)
            .filter!(a => a[0] != '#')) {
        app.put(l.strip);
    }

    return app.data;
}

@("shall parse a file with gitignore syntax")
unittest {
    auto res = parseGitIgnore(`*.[oa]
*.obj
*.svn

# editor junk files
*~
*.orig
tags
*.swp

# dlang
build/
.dub
docs.json
__dummy.html
*.lst
__test__*__

# rust
target/
**/*.rs.bk

# python
*.pyc

repo.tar.gz`);
    assert(res == [
            "*.[oa]", "*.obj", "*.svn", "*~", "*.orig", "tags", "*.swp", "build/",
            ".dub", "docs.json", "__dummy.html", "*.lst", "__test__*__",
            "target/", "**/*.rs.bk", "*.pyc", "repo.tar.gz"
            ]);
}
