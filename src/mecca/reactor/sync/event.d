module mecca.reactor.sync.event;

import mecca.reactor.sync.fiber_queue;
import mecca.lib.exception;
import mecca.lib.time;
import mecca.log;

struct Event {
private:
    FiberQueue waiters;
    bool currentlySet;

public:
    void set() nothrow @safe @nogc {
        DBG_ASSERT!"Event is set but has fibers waiting"(!isSet || waiters.empty);
        if (isSet)
            return;

        currentlySet = true;
        while( !waiters.empty ) {
            waiters.resumeOne();
        }
    }

    void reset() nothrow @safe @nogc {
        DBG_ASSERT!"Event is set but has fibers waiting"(!isSet || waiters.empty);
        currentlySet = false;
    }

    @property bool isSet() const pure nothrow @safe @nogc {
        return currentlySet;
    }

    void wait(Timeout timeout = Timeout.infinite) @safe @nogc {
        while( !isSet ) {
            waiters.suspend(timeout);
        }
    }

    // Wait, potentially with spurious wakeups. Does not require that the event exist after wakeup
    void unreliableWait(Timeout timeout = Timeout.infinite) @safe @nogc {
        if( isSet )
            return;

        waiters.suspend(timeout);
    }
}

unittest {
    import mecca.reactor.fd;
    import mecca.reactor.reactor;

    theReactor.setup();
    scope(exit) theReactor.teardown();

    FD.openReactor();

    Event evt;

    uint counter;
    uint doneCount;
    bool done;

    enum NumWaiters = 30;

    void worker() {
        while(!done) {
            theReactor.yieldThisFiber();
            evt.wait();
            counter++;
        }

        doneCount++;
    }

    void framework() {
        uint savedCounter;

        enum Delay = dur!"msecs"(1);
        foreach(i; 0..10) {
            INFO!"Reset event"();
            evt.reset();
            savedCounter = counter;
            INFO!"Infra begin delay"();
            theReactor.delay(Delay);
            INFO!"Infra end delay"();
            assert(savedCounter == counter, "Worker fibers working while event is reset");

            INFO!"Set event"();
            evt.set();
            INFO!"Infra begin delay2"();
            theReactor.delay(Delay);
            INFO!"Infra end delay2"();
            assert(savedCounter != counter, "Worker fibers not released despite event set");
        }

        INFO!"Reset event end"();
        evt.reset();
        theReactor.yieldThisFiber();

        assert(doneCount==0, "Worker fibers exit while not done");
        done = true;
        INFO!"Infra begin delay end"();
        theReactor.delay(Delay);
        INFO!"Infra end delay end"();

        assert(doneCount==0, "Worker fibers exit with event reset");
        INFO!"Set event end"();
        evt.set();
        INFO!"Infra yeild"();
        theReactor.yieldThisFiber();
        assert(doneCount==NumWaiters, "Not all worker fibers woke up from event");

        INFO!"Infra done"();
        theReactor.stop();
    }

    foreach(i; 0..NumWaiters)
        theReactor.spawnFiber(&worker);

    theReactor.spawnFiber(&framework);


    theReactor.start();
}