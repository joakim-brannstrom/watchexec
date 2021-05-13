/**
Copyright: Copyright (c) 2021, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module watchexec_internal.oneshot;

import logger = std.experimental.logger;
import std.conv : to;
import std.exception : collectException;
import std.json : JSONValue;

import colorlog;
import my.named_type;
import my.hash;
import my.path : AbsolutePath;
import my.filter : GlobFilter;
import my.optional;

struct OneShotFile {
    AbsolutePath path;

    /// unix time in seconds
    long timeStamp;

    this(AbsolutePath path, long timeStamp) {
        this.path = path;
        this.timeStamp = timeStamp;
    }

    this(AbsolutePath path, long timeStamp, Checksum64 cs) {
        this.path = path;
        this.timeStamp = timeStamp;
        this.checksum_ = cs;
        this.hasChecksum = true;
    }

    private {
        Checksum64 checksum_;
        bool hasChecksum;
    }

    Checksum64 checksum() nothrow {
        if (hasChecksum)
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

struct FileChecksumRange {
    import std.file : dirEntries, SpanMode;
    import std.traits : ReturnType;

    private {
        ReturnType!dirEntries entries;
        GlobFilter gf;
    }

    this(AbsolutePath root, GlobFilter gf) {
        this.entries = dirEntries(root, SpanMode.depth);
        this.gf = gf;
    }

    Optional!OneShotFile front() {
        assert(!empty, "Can't get front of an empty range");
        auto f = entries.front;
        if (f.isFile && gf.match(f.name)) {
            return OneShotFile(AbsolutePath(f.name), f.timeLastModified.toUnixTime).some;
        }
        return none!OneShotFile;
    }

    void popFront() @safe {
        assert(!empty, "Can't pop front of an empty range");
        entries.popFront;
    }

    bool empty() @safe {
        return entries.empty;
    }
}

struct FileDb {
    OneShotFile[AbsolutePath] files;

    void add(OneShotFile fc) {
        files[fc.path] = fc;
    }

    bool isChanged(ref OneShotFile fc) {
        if (auto v = fc.path in files) {
            if (v.timeStamp == fc.timeStamp)
                return false;
            return v.checksum != fc.checksum;
        }
        return true;
    }
}

FileDb fromJson(string txt) nothrow {
    import std.json : parseJSON;

    FileDb rval;

    try {
        foreach (a; parseJSON(txt).array) {
            try {
                rval.add(OneShotFile(AbsolutePath(a["p"].str),
                        a["t"].str.to!long, Checksum64(a["c"].str.to!ulong)));
            } catch (Exception e) {
                logger.trace(e.msg).collectException;
            }
        }
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
    JSONValue rval;
    foreach (fc; db.files.byValue) {
        try {
            JSONValue v;
            v["p"] = relativePath(fc.path.toString);
            v["c"] = fc.checksum.c0.to!string;
            v["t"] = fc.timeStamp.to!string;
            app.put(v);
        } catch (Exception e) {
        }
    }

    return JSONValue(app.data);
}
