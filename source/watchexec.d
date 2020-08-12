/**
Copyright: Copyright (c) 2020, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module watchexec;

import core.thread : Thread;
import logger = std.experimental.logger;
import std.algorithm : filter;
import std.array : array, empty;
import std.datetime : Duration;
import std.datetime : dur, Clock;
import std.format : format;

import colorlog;
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

    auto monitor = Monitor(conf.global.paths, 52.dur!"weeks", conf.global.monitorExtensions);

    while (true) {
        auto events = monitor.wait;
        foreach (changed; events) {
            logger.tracef("%s changed", changed);
        }

        if (!events.empty) {
            if (conf.global.debounce != Duration.zero) {
                Thread.sleep(conf.global.debounce);
            }

            if (conf.global.clearScreen) {
                write("\033c");
            }

            // use timeout too when upgrading to proc v1.0.7
            //auto p = spawnProcess(cmd).sandbox.timeout(conf.global.timeout).rcKill;
            auto p = spawnProcess(cmd).sandbox.rcKill;
            logger.info("exit status: ", p.wait);
        }

        monitor.clear;
    }
}

struct AppConfig {
    static import std.getopt;

    static struct Global {
        std.getopt.GetoptResult helpInfo;
        VerboseMode verbosity;
        bool help = true;
        string progName;
        string[] command;
        AbsolutePath[] paths;
        Duration timeout;
        bool useShell;
        Duration debounce;
        bool clearScreen;
        string[] monitorExtensions;

        this(this) {
        }
    }

    Global global;

    void printHelp() {
        std.getopt.defaultGetoptPrinter(format("usage: %s <options> -- <command>\n",
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
        uint timeout = 600;
        uint debounce = 200;
        // dfmt off
        conf.global.helpInfo = std.getopt.getopt(args,
            "c|clear", "clear screen before executing command",&conf.global.clearScreen,
            "d|debounce", format!"set the timeout between detected change and command execution (default: %sms)"(debounce), &debounce,
            "e|ext", "file extensions, including dot, to watch (default: any)", &conf.global.monitorExtensions,
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

/** Monitor root's for filesystem changes which create/remove/modify
 * files/directories.
 *
 * Params:
 *  fileExt = extensions to watch, if null then all. The extension shall include the dot.
 */
struct Monitor {
    import std.algorithm : canFind;
    import std.array : appender;
    import std.file : isDir;
    import std.utf : UTFException;
    import my.fswatch;
    import sumtype;

    Duration timeout;
    string[] fileExt;
    FileWatch fw;

    /**
     * Params:
     *  roots = directories to recursively monitor
     *  fileExt = extensions to watch, if null then all. The extension shall include the dot.
     */
    this(AbsolutePath[] roots, Duration timeout, string[] fileExt) {
        this.timeout = timeout;
        this.fileExt = fileExt;

        fw = fileWatch();
        foreach (r; roots) {
            fw.watchRecurse!(a => isInteresting(fileExt, a))(r);
        }

    }

    static bool isInteresting(string[] fileExt, string p) {
        import std.path : extension;

        if (fileExt.empty) {
            return true;
        }

        if (isDir(p)) {
            return true;
        }
        return canFind(fileExt, p.extension);
    }

    AbsolutePath[] wait() {
        auto rval = appender!(AbsolutePath[])();
        try {
            foreach (e; fw.getEvents(timeout)) {
                e.match!((Event.Access x) {}, (Event.Attribute x) {}, (Event.CloseWrite x) {
                    rval.put(x.path);
                }, (Event.CloseNoWrite x) {}, (Event.Create x) {
                    rval.put(x.path);
                    fw.watchRecurse!(a => isInteresting(fileExt, a))(x.path);
                }, (Event.Modify x) { rval.put(x.path); }, (Event.MoveSelf x) {}, (Event.Delete x) {
                    rval.put(x.path);
                }, (Event.DeleteSelf x) { rval.put(x.path); }, (Event.Rename x) {
                    rval.put(x.to);
                }, (Event.Open x) {},);
            }
        } catch (UTFException e) {
            logger.warning(e.msg);
        }

        return rval.data;
    }

    /// Clear the event listener of any residual events.
    void clear() {
        foreach (e; fw.getEvents(timeout)) {
            e.match!((Event.Access x) {}, (Event.Attribute x) {}, (Event.CloseWrite x) {
            }, (Event.CloseNoWrite x) {}, (Event.Create x) {
                // add any new files/directories to be listened on
                fw.watchRecurse!(a => isInteresting(fileExt, a))(x.path);
            }, (Event.Modify x) {}, (Event.MoveSelf x) {}, (Event.Delete x) {}, (Event.DeleteSelf x) {
            }, (Event.Rename x) {}, (Event.Open x) {},);
        }

        fw.getEvents;
    }
}
