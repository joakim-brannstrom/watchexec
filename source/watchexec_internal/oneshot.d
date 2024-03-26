/**
Copyright: Copyright (c) 2021, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module watchexec_internal.oneshot;

import logger = std.experimental.logger;
import std.algorithm : map;
import std.array : empty, array;
import std.conv : to;
import std.exception : collectException;
import std.json : JSONValue;
import std.range;

import colorlog;
import my.named_type;
import my.hash;
import my.path : AbsolutePath, Path;
import my.filter : GlobFilter;
import my.optional;

alias FileSize = NamedType!(ulong, Tag!"FileSize", ulong.init, TagStringable, Comparable);
alias TimeStamp = NamedType!(long, Tag!"TimeStamp", long.init, TagStringable, Comparable);

struct OneShotFile {
    AbsolutePath path;

    /// unix time in seconds
    TimeStamp timeStamp;

    FileSize size;

    bool hasChecksum;

    private {
        Checksum64 checksum_;
    }

    this(AbsolutePath path, TimeStamp timeStamp, FileSize size) {
        this.path = path;
        this.timeStamp = timeStamp;
        this.size = size;
    }

    this(AbsolutePath path, TimeStamp timeStamp, FileSize size, Checksum64 cs) {
        this.path = path;
        this.timeStamp = timeStamp;
        this.size = size;
        this.checksum_ = cs;
        this.hasChecksum = true;
    }

    Checksum64 checksum() nothrow {
        if (hasChecksum || size.get == 0)
            return checksum_;

        checksum_ = () {
            try {
                return my.hash.checksum!makeChecksum64(path);
            } catch (Exception e) {
                logger.trace(e.msg).collectException;
            }
            return Checksum64.init; // an empty file
        }();
        hasChecksum = true;
        return checksum_;
    }
}

struct OneShotRange {
    import std.file : dirEntries, SpanMode, timeLastModified, getSize, isFile, DirEntry;
    import std.traits : ReturnType;
    import my.file : followSymlink, existsAnd;

    private {
        DirEntry[] entries;
        GlobFilter gf;
        Optional!OneShotFile front_;
        bool followSymlink_;
    }

    this(AbsolutePath root, GlobFilter gf, bool followSymlink) nothrow {
        try {
            this.entries = dirEntries(root, SpanMode.depth).array;
            this.gf = gf;
            this.followSymlink_ = followSymlink;
        } catch (Exception e) {
            logger.trace(e.msg).collectException;
        }
    }

    Optional!OneShotFile front() nothrow {
        assert(!empty, "Can't get front of an empty range");

        if (front_.hasValue)
            return front_;

        () {
            try {
                auto f = () {
                    if (entries.front.isSymlink && followSymlink_)
                        return followSymlink(Path(entries.front.name)).orElse(Path.init).toString;
                    return entries.front.name;
                }();

                if (f.empty)
                    return;

                if (Path(f).existsAnd!isFile && gf.match(f)) {
                    front_ = OneShotFile(AbsolutePath(f),
                            f.timeLastModified.toUnixTime.TimeStamp, f.getSize.FileSize).some;
                }
            } catch (Exception e) {
                logger.trace(e.msg).collectException;
                front_ = none!OneShotFile;
            }
        }();

        return front_;
    }

    void popFront() @trusted nothrow {
        assert(!empty, "Can't pop front of an empty range");

        front_ = none!OneShotFile;

        try {
            entries.popFront;
        } catch (Exception e) {
            logger.trace(e.msg).collectException;
        }
    }

    bool empty() @safe nothrow {
        try {
            return entries.empty;
        } catch (Exception e) {
            try {
                logger.trace(e.msg);
            } catch (Exception e) {
            }
        }
        return true;
    }
}

struct FileDb {
    OneShotFile[AbsolutePath] files;
    string[] command;

    void add(OneShotFile fc) {
        files[fc.path] = fc;
    }

    bool isChanged(ref OneShotFile fc) {
        if (auto v = fc.path in files) {
            if (v.size != fc.size)
                return true;
            if (v.timeStamp == fc.timeStamp && v.size == fc.size)
                return false;
            return v.checksum != fc.checksum;
        }
        return true;
    }
}

FileDb fromJson(string txt) nothrow {
    import std.json : parseJSON;

    FileDb rval;

    auto json = () {
        try {
            return parseJSON(txt);
        } catch (Exception e) {
            logger.info(e.msg).collectException;
        }
        return JSONValue.init;
    }();

    try {
        foreach (a; json["files"].array) {
            try {
                rval.add(OneShotFile(AbsolutePath(a["p"].str),
                        a["t"].str.to!long.TimeStamp,
                        a["s"].str.to!ulong.FileSize, Checksum64(a["c"].str.to!ulong)));
            } catch (Exception e) {
                logger.trace(e.msg).collectException;
            }
        }
    } catch (Exception e) {
        logger.info(e.msg).collectException;
    }
    try {
        rval.command = json["cmd"].array.map!(a => a.str).array;
    } catch (Exception e) {
        logger.info(e.msg).collectException;
    }

    return rval;
}

@("shall parse to the file database")
unittest {
    auto txt = `[{"p": "foo/bar", "c": "1234", "t": "42"}]`;
    auto db = fromJson(txt);
    assert(AbsolutePath("foo/bar") in db.files);
    assert(db.files[AbsolutePath("foo/bar")].checksum == Checksum64(1234));
}

JSONValue toJson(ref FileDb db) {
    import std.array : appender;
    import std.path : relativePath;

    auto app = appender!(JSONValue[])();
    foreach (fc; db.files.byValue) {
        try {
            JSONValue v;
            v["p"] = relativePath(fc.path.toString);
            v["c"] = fc.hasChecksum ? fc.checksum.c0.to!string : "0";
            v["t"] = fc.timeStamp.get.to!string;
            v["s"] = fc.size.get.to!string;
            app.put(v);
        } catch (Exception e) {
        }
    }
    JSONValue rval;
    rval["files"] = app.data;
    rval["cmd"] = db.command;

    return rval;
}
