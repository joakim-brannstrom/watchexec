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
import std.format : format;

import colorlog;
import my.filter;
import my.path;

int main(string[] args) {
    confLogger(VerboseMode.info);

    auto conf = parseUserArgs(args);

    confLogger(conf.global.verbosity);

    if (conf.global.help)
        return cliHelp(conf);
    return cli(conf);
}

private:

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
    logger.infof("watching directories for change: %s", conf.global.paths);

    const cmd = () {
        if (conf.global.useShell)
            return ["/bin/sh", "-c"] ~ format!"%-(%s %)"(conf.global.command);
        return conf.global.command;
    }();

    auto monitor = Monitor(conf.global.paths, ReFilter(conf.global.include, conf.global.exclude), conf.global.watchMetadata ? (ContentEvents | MetadataEvents) : ContentEvents);

    MonitorResult[] eventFiles;

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
                env["WATCHEXEC_EVENT"] = eventFiles.map!(a => format!"%s:%s"(a.kind, a.path))
                    .joiner(";").text;
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
                        printExitStatus(p.status);
                    } else {
                        p.kill;
                        p.wait;
                    }
                } else {
                    p.wait;
                    printExitStatus(p.status);
                }
                monitor.clear;
            } catch (Exception e) {
                logger.error(e.msg);
                return 1;
            }

        }
    }
}

void printExitStatus(int code) {
    import std.conv : to;

    auto msg = () {
        if (code == 0)
            return "exit status".color(Color.green);
        return "exit status".color(Color.red);
    }();

    logger.info(msg, " ", code);
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
        bool useShell;
        bool watchMetadata;
        string progName;
        string[] command;
        string[] monitorExtensions;

        string include = ".*";
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
    static import std.getopt;

    AppConfig conf;
    conf.global.progName = args[0].baseName;

    try {
        const idx = countUntil(args, "--");
        if (args.length > 1 && idx > 1) {
            conf.global.command = args[idx + 1 .. $];
            args = args[0 .. idx];
        }

        string[] paths;
        uint timeout = 3600;
        uint debounce = 200;
        // dfmt off
        conf.global.helpInfo = std.getopt.getopt(args,
            "c|clear", "clear screen before executing command",&conf.global.clearScreen,
            "d|debounce", format!"set the timeout between detected change and command execution (default: %sms)"(debounce), &debounce,
            "env", "set WATCHEXEC_*_PATH environment variables when executing the command", &conf.global.setEnv,
            "e|ext", "file extensions, including dot, to watch (default: any)", &conf.global.monitorExtensions,
            "meta", "watch for metadata changes (date, open/close, permission)", &conf.global.watchMetadata,
            "re-exclude", "ignore modifications to paths matching the pattern (regex: .*)", &conf.global.exclude,
            "re-include", "ignore all modifications except those matching the pattern (regex: <empty>)", &conf.global.include,
            "r|restart", "restart the process if it's still running", &conf.global.restart,
            "shell", "run the command in a shell (/bin/sh)", &conf.global.useShell,
            "t|timeout", format!"max runtime of the command (default: %ss)"(timeout), &timeout,
            "v|verbose", format("Set the verbosity (%-(%s, %))", [EnumMembers!(VerboseMode)]), &conf.global.verbosity,
            "w|watch", "watch a specific directory", &paths,
            );
        // dfmt on

        conf.global.help = conf.global.helpInfo.helpWanted;
        conf.global.timeout = timeout.dur!"seconds";
        conf.global.debounce = debounce.dur!"msecs";
        conf.global.paths = paths.map!(a => AbsolutePath(a)).array;
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
        Access ,
        Attribute ,
        CloseWrite ,
        CloseNoWrite ,
        Create ,
        Delete ,
        DeleteSelf ,
        Modify ,
        MoveSelf ,
        Rename ,
        Open ,
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

    FileWatch fw;
    ReFilter fileFilter;
    uint events;

    /**
     * Params:
     *  roots = directories to recursively monitor
     */
    this(AbsolutePath[] roots, ReFilter fileFilter, uint events = ContentEvents) {
        this.fileFilter = fileFilter;
        this.events = events;

        auto app = appender!(AbsolutePath[])();
        fw = fileWatch();
        foreach (r; roots) {
            app.put(fw.watchRecurse(r, events));
        }

        logger.trace(!app.data.empty, "unable to watch ", app.data);
    }

    MonitorResult[] wait(Duration timeout) {
        import my.set;

        auto rval = appender!(MonitorResult[])();
        try {
            foreach (e; fw.getEvents(timeout)) {
                e.match!((Event.Access x) { rval.put(MonitorResult(MonitorResult.Kind.Access, x.path)); }, (Event.Attribute x) { rval.put(MonitorResult(MonitorResult.Kind.Attribute, x.path)); }, (Event.CloseWrite x) {
rval.put(MonitorResult(MonitorResult.Kind.CloseWrite, x.path));
                }, (Event.CloseNoWrite x) { rval.put(MonitorResult(MonitorResult.Kind.CloseNoWrite, x.path)); }, (Event.Create x) {
rval.put(MonitorResult(MonitorResult.Kind.Create, x.path));
                    fw.watchRecurse(x.path, events);
                }, (Event.Modify x) {
rval.put(MonitorResult(MonitorResult.Kind.Modify, x.path));
                 }, (Event.MoveSelf x) {
                 rval.put(MonitorResult(MonitorResult.Kind.MoveSelf, x.path));
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

        return rval.data
            .filter!(a => fileFilter.match(a.path))
            .array;
    }

    /// Clear the event listener of any residual events.
    void clear() {
        foreach (e; fw.getEvents(Duration.zero)) {
            e.match!((Event.Access x) {}, (Event.Attribute x) {}, (Event.CloseWrite x) {
            }, (Event.CloseNoWrite x) {}, (Event.Create x) {
                // add any new files/directories to be listened on
                fw.watchRecurse(x.path, events);
            }, (Event.Modify x) {}, (Event.MoveSelf x) {}, (Event.Delete x) {}, (Event.DeleteSelf x) {
            }, (Event.Rename x) {}, (Event.Open x) {},);
        }

        fw.getEvents;
    }
}
