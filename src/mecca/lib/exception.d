/// When things go wrong....
module mecca.lib.exception;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

public import core.exception: AssertError, RangeError;
public import std.exception: ErrnoException;
import std.algorithm : min;
import std.traits;
import core.exception: assertHandler;
import core.runtime: Runtime, defaultTraceHandler;

import mecca.log;
import mecca.lib.reflection: as;
import mecca.lib.string : nogcFormat, nogcRtFormat;

// Disable tracing instrumentation for the whole file
@("notrace") void traceDisableCompileTimeInstrumentation();

private extern(C) nothrow @nogc {
    int backtrace(void** buffer, int size);

    static if (__VERSION__ < 2077) {
        pragma(mangle, "_D4core7runtime19defaultTraceHandlerFPvZ16DefaultTraceInfo6__ctorMFZC4core7runtime19defaultTraceHandlerFPvZ16DefaultTraceInfo")
            void defaultTraceInfoCtor(Object);
    } else {
        pragma(mangle, "_D4core7runtime19defaultTraceHandlerFPvZ16DefaultTraceInfo6__ctorMFZCQCpQCnQCiFQBqZQBr")
            void defaultTraceInfoCtor(Object);
    }
}
private __gshared static TypeInfo_Class defaultTraceTypeInfo;

shared static this() {
    defaultTraceTypeInfo = typeid(cast(Object)defaultTraceHandler(null));
    assert(defaultTraceTypeInfo.name == "core.runtime.defaultTraceHandler.DefaultTraceInfo", defaultTraceTypeInfo.name);
    assert(defaultTraceTypeInfo.initializer.length <= ExcBuf.MAX_TRACEBACK_SIZE);
    assert(DefaultTraceInfoABI.sizeof <= defaultTraceTypeInfo.initializer.length);
    version (unittest) {} else {
        assertHandler = &assertHandlerImpl;
    }
}

extern(C) private void ALREADY_EXTRACTING_STACK() {
    assert (false, "you're not supposed to call this function");
}

/**
 * Extract the stack backtrace.
 *
 * The pointers returned from the function are one less than the actual number. This is so that a symbol lookup will report the
 * correct function even when the call to _d_throw_exception was the last thing in it.
 *
 * Params:
 * callstack = range to receive the call stack pointers
 * skip = number of near frames to skip.
 *
 * Retruns:
 * Range where the actual pointers reside.
 */
void*[] extractStack(void*[] callstack, size_t skip = 0) nothrow @trusted @nogc {
    /* thread local */ static bool alreadyExtractingStack = false;
    if (alreadyExtractingStack) {
        // stack extraction is apparently non re-entrant, and because we want signal handlers
        // to be able to use this function, we just return a mock stack in this case.
        callstack[0] = &ALREADY_EXTRACTING_STACK;
        callstack[1] = &ALREADY_EXTRACTING_STACK;
        callstack[2] = &ALREADY_EXTRACTING_STACK;
        callstack[3] = null;
        return callstack[0 .. 4];
    }
    alreadyExtractingStack = true;
    scope(exit) alreadyExtractingStack = false;

    auto numFrames = backtrace(callstack.ptr, cast(int)callstack.length);
    auto res = callstack[skip .. numFrames];

    // Adjust the locations by one byte so they point inside the function (as
    // required by backtrace_symbols) even if the call to _d_throw_exception
    // was the very last instruction in the function.
    foreach (ref c; res) {
        c -= 1;
    }
    return res;
}

struct DefaultTraceInfoABI {
    import mecca.lib.reflection: isVersion;

    void*    _vtbl;
    void*    _monitor;
    void*    _interface;  // introduced in DMD 2.071
    // make sure the ABI matches
    static assert ({static interface I {} static class C: I {} return __traits(classInstanceSize, C);}() == (void*[3]).sizeof);

    int      numframes;
    void*[0] callstack;

    static DefaultTraceInfoABI* extract(Throwable.TraceInfo traceInfo) nothrow @trusted @nogc {
        auto obj = cast(Object)traceInfo;
        assert (typeid(obj).name == "core.runtime.defaultTraceHandler.DefaultTraceInfo", typeid(obj).name);
        return cast(DefaultTraceInfoABI*)(cast(void*)obj);
    }
    static DefaultTraceInfoABI* extract(Throwable ex) nothrow @safe @nogc {
        return extract(ex.info);
    }
    @property void*[] frames() nothrow @trusted @nogc {
        return callstack.ptr[0 .. numframes];
    }
}

/// Static buffer for storing no GC exceptions
struct ExcBuf {
    enum MAX_EXCEPTION_INSTANCE_SIZE = 256;
    enum MAX_EXCEPTION_MESSAGE_SIZE = 256;
    enum MAX_TRACEBACK_SIZE = 1064;

    ubyte[MAX_EXCEPTION_INSTANCE_SIZE] ex;
    ubyte[MAX_TRACEBACK_SIZE] ti;
    char[MAX_EXCEPTION_MESSAGE_SIZE] msgBuf;

    /// Get the Throwable stored in the buffer
    Throwable get() nothrow @trusted @nogc {
        if (*(cast(void**)ex.ptr) is null) {
            return null;
        }
        return cast(Throwable)ex.ptr;
    }

    /// Set the exception that buffer is to hold.
    Throwable set(Throwable t, bool setTraceback = false) nothrow @trusted @nogc {
        static assert (this.ex.offsetof == 0);
        if (t is null) {
            *(cast(void**)ex.ptr) = null;
            return null;
        }

        if (t is get()) {
            // don't assign to yourself to yourself
            if (setTraceback) {
                this.setTraceback(t);
            }
            return t;
        }

        auto len = typeid(t).initializer.length;
        ex[0 .. len] = (cast(ubyte*)t)[0 .. len];
        auto tobj = cast(Throwable)ex.ptr;

        if (setTraceback) {
            this.setTraceback(t);
        }
        else {
            if (t.info is null) {
                tobj.info = null;
                *(cast(void**)ti.ptr) = null;
            }
            else {
                auto tinfo = cast(Object)t.info;
                assert (tinfo !is null, "casting TraceInfo to Object failed");
                len = typeid(tinfo).m_init.length;
                ti[0 .. len] = (cast(ubyte*)tinfo)[0 .. len];
                tobj.info = cast(Throwable.TraceInfo)(cast(Object)ti.ptr);
            }
        }

        setMsg(t.msg, t);
        return tobj;
    }

    /**
     * set a Throwable's backtrace to the current point.
     *
     * Params:
     * tobj = the Throwable which backtrace to set. If null, set the buffer's Throwable (which must not be null).
     */
    void setTraceback(Throwable tobj) nothrow @trusted @nogc {
        if (tobj is null) {
            tobj = get();
            assert (tobj !is null, "setTraceback of unset exception");
        }
        ti[0 .. DefaultTraceInfoABI.sizeof] = cast(ubyte[])(defaultTraceTypeInfo.initializer[0 .. DefaultTraceInfoABI.sizeof]);
        auto tinfo = cast(Object)ti.ptr;
        defaultTraceInfoCtor(tinfo);
        tobj.info = cast(Throwable.TraceInfo)tinfo;
    }

    /**
     * Construct a throwable in place
     *
     * Params:
     * file = the reported source file of the exception
     * line = the reported source file line of the exception
     * setTraceback = whether to set the stack trace
     * args = arguments to pass to the exception's constructor
     */
    T construct(T:Throwable, A...)(string file, size_t line, bool setTraceback, auto ref A args) nothrow @trusted @nogc
    {
        T t = constructHelper!T(file, line, setTraceback, args);
        setMsg(t.msg, t);
        return t;
    }

    /**
     * Construct a Throwable, formatting the message
     *
     * Construct a `Throwable` that has a constructor that accepts a single string argument (such as `Exception`). Allows
     * formatting arguments into the string in a non GC way.
     *
     * Second form of the function receives the string as a template argument, and verifies that the arguments match the
     * format string.
     */
    T constructFmt(T: Throwable = Exception, A...)(string file, size_t line, string fmt, auto ref A args) @trusted {
        auto tmpMsg = nogcRtFormat(msgBuf[], fmt, args);
        return constructHelper!T(file, line, true, tmpMsg);
    }

    unittest {
        ExcBuf ex;
        ex.constructFmt!Exception("file.d", 31337, "%s was a %s %s", "pappa", "rolling", "stoner");

        assert( ex.get().msg=="pappa was a rolling stoner" );
    }

    /// ditto
    T constructFmt(string fmt, T: Throwable = Exception, A...)(string file, size_t line, auto ref A args) @trusted {
        auto tmpMsg = nogcFormat!fmt(msgBuf[], args);
        return constructHelper!T(file, line, true, tmpMsg);
    }

    unittest {
        ExcBuf ex;
        ex.constructFmt!("I'm %s in %s", Exception)("file.d", 31337, "an Englishman", "New York");

        assert( ex.get().msg=="I'm an Englishman in New York" );

        static assert( !__traits(compiles,
                ex.constructFmt!("No arguments, please", Exception)("file.d", 31337, "An argument")) );
    }

    void setMsg(const(char)[] msg2, Throwable tobj = null) nothrow @nogc {
        if (tobj is null) {
            tobj = get();
            assert (tobj);
        }
        if (msg2 is null || msg2.length == 0) {
            tobj.msg = null;
        }
        else if (msg2.length > msgBuf.length) {
            msgBuf[] = msg2[0 .. msgBuf.length];
            tobj.msg = cast(string)msgBuf[];
        }
        else {
            msgBuf[0 .. msg2.length] = msg2[];
            tobj.msg = cast(string)msgBuf[0 .. msg2.length];
        }
    }

    static bool isGCException(Throwable ex) {
        import core.memory: GC;
        return GC.addrOf(cast(void*)ex) !is null;
    }

    static Throwable toGC(Throwable ex, bool forceCopy=false) {
        if (!forceCopy && isGCException(ex)) {
            // already GC-allocated
            return ex;
        }
        auto buf = new ExcBuf;
        return buf.set(ex);
    }

private:
    T constructHelper(T:Throwable, A...)(
            string file, size_t line, bool setTraceback, auto ref A args) nothrow @trusted @nogc
    {
        static assert (__traits(classInstanceSize, T) <= ExcBuf.MAX_EXCEPTION_INSTANCE_SIZE);

        // create the exception
        ex[0 .. __traits(classInstanceSize, T)] = cast(ubyte[])typeid(T).initializer[];
        auto t = cast(T)ex.ptr;
        as!"nothrow @nogc"({t.__ctor(args);});
        t.file = file;
        t.line = line;
        t.info = null;

        if (setTraceback) {
            this.setTraceback(t);
        }

        return t;
    }
}

/* thread local*/ static ExcBuf _tlsExcBuf;
/* thread local*/ static ExcBuf* _currExcBuf;
/* thread local*/ static this() {_currExcBuf = &_tlsExcBuf;}

void switchCurrExcBuf(ExcBuf* newCurrentExcBuf) nothrow @safe @nogc {
    if (newCurrentExcBuf !is null)
        _currExcBuf = newCurrentExcBuf;
    else
        _currExcBuf = &_tlsExcBuf;
}

T mkEx(T: Throwable, string file = __FILE__, size_t line = __LINE__, A...)(auto ref A args) @safe @nogc {
    version(LDC)
            // Must inline because of __FILE__ as template parameter. https://github.com/ldc-developers/ldc/issues/1703
            pragma(inline, true);

    return mkExLine!T(file, line, args);
}

T mkExLine(T: Throwable, A...)(string file, size_t line, auto ref A args) @safe @nogc {
    return _currExcBuf.construct!T(file, line, true, args);
}

T mkExFmt(T: Throwable, string file = __FILE__, size_t line = __LINE__, A...)(string fmt, auto ref A args) @safe @nogc
{
    version(LDC)
            // Must inline because of __FILE__ as template parameter. https://github.com/ldc-developers/ldc/issues/1703
            pragma(inline, true);

    return _currExcBuf.constructFmt!T(file, line, fmt, args);
}

T mkExFmt(string fmt, T: Throwable = Exception, string file = __FILE__, size_t line = __LINE__, A...)(auto ref A args)
    @safe @nogc
{
    version(LDC)
            // Must inline because of __FILE__ as template parameter. https://github.com/ldc-developers/ldc/issues/1703
            pragma(inline, true);

    return _currExcBuf.constructFmt!(fmt, T)(file, line, args);
}

Throwable setEx(Throwable ex, bool setTraceback = false) nothrow @safe @nogc {
    return _currExcBuf.set(ex, setTraceback);
}

RangeError rangeError(K, string file=__FILE__, size_t line=__LINE__)(K key, string msg = "Index/key not found") {
    version(LDC)
            // Must inline because of __FILE__ as template parameter. https://github.com/ldc-developers/ldc/issues/1703
            pragma(inline, true);

    static if ( __traits(compiles, sformat(null, "%s", key))) {
        return mkExFmt!("%s: %s", RangeError, file, line)(msg, key);
    }
    else {
        return mkExFmt!("%s: %s", RangeError, file, line)(msg, K.stringof);
    }
}

void enforceFmt(T: Throwable = Exception, string file = __FILE__, size_t line = __LINE__, A...)(
        bool cond, string fmt, auto ref A args) @safe @nogc
{
    version(LDC)
            // Must inline because of __FILE__ as template parameter. https://github.com/ldc-developers/ldc/issues/1703
            pragma(inline, true);

    if (!cond) {
        throw mkExFmt!(T, file, line)(fmt, args);
    }
}


mixin template ExceptionBody(string msg) {
    this(string file = __FILE__, size_t line = __LINE__, Throwable next = null) @safe pure nothrow @nogc {
        super(msg, file, line, next);
    }
}

mixin template ExceptionBody() {
    this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null) @safe pure nothrow @nogc {
        super(msg, file, line, next);
    }
    /+import mecca.lib.exception: ExcBuf;
    __gshared static ExcBuf* _singletonExBuf;

    shared static this() {
        _singletonExBuf = new ExcBuf;
    }
    @("notrace") static typeof(this) singleton(string file = __FILE__, size_t line = __LINE__) {
        import mecca.tracing.api: LOG_TRACEBACK;
        auto ex = _singletonExBuf.construct!(typeof(this))(file, line, true, (staticMsg.length == 0 ? typeof(this).stringof : staticMsg));
        LOG_TRACEBACK(ex);
        return ex;
    }+/
}

unittest {
    import std.stdio;
    class MyException: Exception {mixin ExceptionBody;}
    class YourException: Exception {mixin ExceptionBody;}

    bool thrown1 = false;
    try {
        throw mkEx!MyException("hello world");
    }
    catch (MyException ex) {
        assert (ex.msg == "hello world");
        thrown1 = true;
    }
    assert (thrown1);

    auto ex2 = new YourException("foo bar");
    bool thrown2 = false;
    try {
        throw setEx(ex2);
    }
    catch (YourException ex) {
        assert (ex !is ex2);
        assert(ex.msg == "foo bar");
        thrown2 = true;
    }
    assert (thrown2);
}

private @notrace void assertHandlerImpl(string file, size_t line, string msg) nothrow @nogc {
    pragma(inline, true);
    DIE(msg, file, line);
}

void function(string msg, string file, size_t line) blowUpHandler;

@notrace void DIE(string msg, string file = __FILE__, size_t line = __LINE__, bool doAbort=false) nothrow @nogc {
    import core.sys.posix.unistd: write, _exit;
    import core.stdc.stdlib: abort;
    import core.atomic: cas;

    // block threads racing into this function
    shared static bool recLock = false;
    while (!cas(&recLock, false, true)) {}

    __gshared static ExcBuf excBuf;
    as!"nothrow @nogc"({
        if( loggingInitialized ) {
            META!"Assertion failure(%s:%s) %s"(file, line, msg);
            flushLog();
        }
        auto ex = excBuf.construct!AssertError(file, line, true, msg);
        ex.toString((text){write(2, text.ptr, text.length);});
        if (doAbort) {
            abort();
        }
        else {
            _exit(1);
        }
    });
    assert(false);
}

void ABORT(string msg, string file = __FILE__, size_t line = __LINE__) nothrow @nogc {
    DIE(msg, file, line, true);
}

void ASSERT
    (string fmt, string file = __FILE__, string mod = __MODULE__, size_t line = __LINE__, T...)
    (bool cond, scope lazy T args)
    pure nothrow @trusted @nogc
{
    version(LDC)
            // Must inline because of __FILE__ as template parameter. https://github.com/ldc-developers/ldc/issues/1703
            pragma(inline, true);

    if (cond) {
        return;
    }

    scope f = () {
        META!("ASSERT at %s:%s")(file, line);
        static if( !LogToConsole ) {
            // Also log to stderr, as the logger doesn't do that for us.
            import std.stdio: stderr;
            stderr.writefln( "Assertion failure at %s:%s: " ~ fmt, file, line, args );
        }
    };
    as!"@nogc pure nothrow"(f);
    version(unittest ){
        as!"@nogc pure nothrow"({
            import std.string: format;
            throw new AssertError( format("Assertion failure: " ~ fmt, args), file, line);
        });
    }
    else {
        as!"@nogc pure nothrow"({
            import std.string: format;
            DIE(format( "Assertion failure: " ~ fmt, args), file, line);
        });
    }
}

void enforceNGC(Ex : Throwable = Exception, string file = __FILE__, size_t line = __LINE__)
    (bool value, scope lazy string msg = null) @trusted @nogc
{
    version(LDC)
            // Must inline because of __FILE__ as template parameter. https://github.com/ldc-developers/ldc/issues/1703
            pragma(inline, true);

    if( !value ) {
        string evaluatedMsg;
        as!"@nogc"({evaluatedMsg = msg;});
        throw mkEx!Ex(evaluatedMsg, file, line);
    }
}

void errnoEnforceNGC(string file = __FILE__, size_t line = __LINE__)
    (bool value, scope lazy string msg = null) @trusted @nogc
{
    version(LDC)
            // Must inline because of __FILE__ as template parameter. https://github.com/ldc-developers/ldc/issues/1703
            pragma(inline, true);

    as!"@nogc"({ enforceNGC!(ErrnoException, file, line)(value, msg); });
}

version(assert) {
    alias DBG_ASSERT = ASSERT;
}
else {
    void DBG_ASSERT(string fmt, string file = __FILE__, size_t line = __LINE__, T...)(scope lazy bool cond, scope lazy T args) @nogc {
        pragma(inline, true);
    }
}

unittest {
    ASSERT!"oh no: %s"(true, "foobar");
}


//
// useful assert variants
//
@notrace void assertOp(string op, L, R, string file = __FILE__, string mod = __MODULE__, size_t line = __LINE__)
    (L lhs, R rhs, string msg="") nothrow
{
    version(LDC)
            // Must inline because of __FILE__ as template parameter. https://github.com/ldc-developers/ldc/issues/1703
            pragma(inline, true);

    static assert(
             !is(Unqual!LHS == enum) || is(Unqual!LHS == Unqual!RHS),
            "comparing different enums is unsafe: " ~ LHS.stringof ~ " != " ~ RHS.stringof);

    import std.meta: staticIndexOf;
    enum idx = staticIndexOf!(op, "==", "!=", ">", "<", ">=", "<=", "in", "!in", "is", "!is");
    static assert (idx >= 0, "assertOp called with operation \"" ~ op ~ "\" which is not supported");
    enum inverseOp = ["!=", "==", "<=", ">=", "<", ">", "!in", "in", "!is", "is"][idx];

    auto lhsVal = lhs;
    auto rhsVal = rhs;
    ASSERT!("%s %s %s %s", file, mod, line)(mixin("lhsVal " ~ op ~ " rhsVal"), lhs, inverseOp, rhs, msg);
}

@notrace void assertEQ(L, R, string file = __FILE__, string mod = __MODULE__, size_t line = __LINE__)(L lhs, R rhs, string msg="") nothrow {
    assertOp!("==", L, R, file, mod, line)(lhs, rhs, msg);
}
@notrace void assertNE(L, R, string file = __FILE__, string mod = __MODULE__, size_t line = __LINE__)(L lhs, R rhs, string msg="") nothrow {
    assertOp!("!=", L, R, file, mod, line)(lhs, rhs, msg);
}
@notrace void assertGT(L, R, string file = __FILE__, string mod = __MODULE__, size_t line = __LINE__)(L lhs, R rhs, string msg="") nothrow {
    assertOp!(">", L, R, file, mod, line)(lhs, rhs, msg);
}
@notrace void assertGE(L, R, string file = __FILE__, string mod = __MODULE__, size_t line = __LINE__)(L lhs, R rhs, string msg="") nothrow {
    assertOp!(">=", L, R, file, mod, line)(lhs, rhs, msg);
}
@notrace void assertLT(L, R, string file = __FILE__, string mod = __MODULE__, size_t line = __LINE__)(L lhs, R rhs, string msg="") nothrow {
    assertOp!("<", L, R, file, mod, line)(lhs, rhs, msg);
}
@notrace void assertLE(L, R, string file = __FILE__, string mod = __MODULE__, size_t line = __LINE__)(L lhs, R rhs, string msg="") nothrow {
    assertOp!("<=", L, R, file, mod, line)(lhs, rhs, msg);
}

version(unittest) {
    void assertThrows(T = Throwable, E, string file = __FILE__, string mod = __MODULE__, size_t line = __LINE__)(scope lazy E expr) {
        try {
            expr();
        }
        catch (Throwable ex) {
            ASSERT!("Threw %s instead of %s", file, mod, line)(cast(T)ex !is null, typeid(ex).name, T.stringof);
            return;
        }
        ASSERT!("Did not throw", file, mod, line)(false);
    }
}

unittest {
    assertEQ(7, 7);
    assertNE(7, 17);
    assertThrows(assertEQ(7, 17));
}

int errnoCall(alias F, string file=__FILE__, size_t line=__LINE__)(Parameters!F args) @nogc if (is(ReturnType!F == int))
{
    version(LDC)
            // Must inline because of __FILE__ as template parameter. https://github.com/ldc-developers/ldc/issues/1703
            pragma(inline, true);

    int res = F(args);
    if (res < 0) {
        import std.range: repeat;
        import std.string;
        enum fmt = __traits(identifier, F) ~ "(" ~ "%s".repeat(args.length).join(", ") ~ ")";
        throw mkExFmt!(fmt, ErrnoException, file, line)(args);
    }
    return res;
}

unittest {
    import core.sys.posix.unistd: dup, close;
    auto newFd = errnoCall!dup(1);
    assert (newFd >= 0);
    errnoCall!close(newFd);
    // double close will throw
    assertThrows!ErrnoException(errnoCall!close(newFd));
}





