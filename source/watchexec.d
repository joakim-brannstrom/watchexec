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
import my.fswatch : Monitor, MonitorResult;
import my.filter : GlobFilter;

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
    logger.infof("setting up notification for changes of: %s", conf.global.paths);

    const cmd = () {
        if (conf.global.useShell)
            return ["/bin/sh", "-c"] ~ format!"%-(%s %)"(conf.global.command);
        return conf.global.command;
    }();

    auto monitor = Monitor(conf.global.paths, GlobFilter(conf.global.include,
            conf.global.exclude), conf.global.watchMetadata
            ? (ContentEvents | MetadataEvents) : ContentEvents);
    logger.info("starting");

    auto handleExitStatus = HandleExitStatus(conf.global.useNotifySend);

    MonitorResult[] buildAndExecute(MonitorResult[] eventFiles) {
        string[string] env;
        MonitorResult[] rval;

        if (conf.global.setEnv) {
            env["WATCHEXEC_EVENT"] = eventFiles.map!(a => format!"%s:%s"(a.kind,
                    a.path)).joiner(";").text;
        }

        auto p = spawnProcess(cmd, env).sandbox.timeout(conf.global.timeout).rcKill;

        if (conf.global.restart) {
            while (!p.tryWait && rval.empty) {
                rval = monitor.wait(10.dur!"msecs");
            }

            if (rval.empty) {
                handleExitStatus.exitStatus(p.status);
            } else {
                p.kill;
                p.wait;
            }
        } else {
            p.wait;
            handleExitStatus.exitStatus(p.status);
        }

        if (conf.global.clearEvents) {
            // the events can fire a bit late when e.g. writing to an NFS mount
            // point.
            monitor.collect(10.dur!"msecs");
        }

        return rval;
    }

    MonitorResult[] eventFiles;

    if (!conf.global.postPone) {
        try {
            eventFiles = buildAndExecute(null);
        } catch (Exception e) {
            logger.error(e.msg);
            return 1;
        }
    }

    while (true) {
        if (eventFiles.empty) {
            eventFiles = monitor.wait(1000.dur!"weeks");
        }

        foreach (changed; eventFiles) {
            logger.tracef("%s changed", changed);
        }

        if (!eventFiles.empty) {
            if (conf.global.debounce != Duration.zero) {
                eventFiles ~= monitor.collect(conf.global.debounce);
            }

            if (conf.global.clearScreen) {
                write("\033c");
            }

            try {
                eventFiles = buildAndExecute(eventFiles);
            } catch (Exception e) {
                logger.error(e.msg);
                return 1;
            }

        }
    }
}

struct HandleExitStatus {
    bool useNotifySend;
    string notifyMsg;

    this(string notifyMsg) {
        this.useNotifySend = !notifyMsg.empty;
        this.notifyMsg = notifyMsg;
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
                    return format!"%s %s %s\n%s"(msgOk, msgExitStatus, code, notifyMsg);
                return format!"%s %s %s\n%s"(msgNok, msgExitStatus, code, notifyMsg);
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
        bool clearEvents;
        bool clearScreen;
        bool postPone;
        bool restart;
        bool setEnv;
        bool useShell;
        bool watchMetadata;
        string progName;
        string useNotifySend;
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

        bool noClearEvents;
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
            "no-clear-events", "do not clear the events that occured when executing the command", &noClearEvents,
            "no-default-ignore", "skip auto-ignoring of commonly ignored globs", &noDefaultIgnore,
            "no-vcs-ignore", "skip auto-loading of .gitignore files for filtering", &noVcsIgnore,
            "notify", format!"use %s for desktop notification with commands exit status and this msg"(notifySendCmd), &conf.global.useNotifySend,
            "p|postpone", "wait until first change to execute command", &conf.global.postPone,
            "r|restart", "restart the process if it's still running", &conf.global.restart,
            "shell", "run the command in a shell (/bin/sh)", &conf.global.useShell,
            "t|timeout", format!"max runtime of the command (default: %ss)"(timeout), &timeout,
            "v|verbose", format("Set the verbosity (%-(%s, %))", [EnumMembers!(VerboseMode)]), &conf.global.verbosity,
            "w|watch", "watch a specific directory", &paths,
            );
        // dfmt on

        conf.global.clearEvents = !noClearEvents;

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
                conf.global.useNotifySend = null;
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
