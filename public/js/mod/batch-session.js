/** One socket owns one queue, one outstanding archive and its cooldown timer. */
export function createBatchSession({
    socket, archives, command, cooldown = 0, onResult, onWait, onError, onClose,
    schedule = setTimeout, unschedule = clearTimeout,
}) {
    const queue = [...archives];
    const delay = Math.min(20, Math.max(0, Number(cooldown) || 0));
    let active = true;
    let pending = null;
    let timer = null;

    function stop() {
        active = false;
        if (timer !== null) unschedule(timer);
        timer = null;
        pending = null;
    }

    function sendNext() {
        timer = null;
        if (!active || pending !== null) return;
        if (!queue.length) {
            stop();
            socket.close(1000);
            return;
        }
        pending = queue.shift();
        try {
            socket.send(JSON.stringify({ ...command, archive: pending }));
        } catch (error) {
            fail(error);
        }
    }

    function fail(error) {
        if (!active) return;
        stop();
        onError(error);
        socket.close();
    }

    socket.onopen = sendNext;
    socket.onmessage = (event) => {
        if (!active || pending === null) return;
        let result;
        try {
            result = JSON.parse(event.data);
            if (!result || result.id !== pending || ![0, 1].includes(result.success)) {
                throw new Error("Invalid batch response");
            }
        } catch (error) {
            fail(error);
            return;
        }
        pending = null;
        onResult(result);
        if (!active) return;
        if (!queue.length) {
            stop();
            socket.close(1000);
        } else {
            if (delay) onWait(delay);
            timer = schedule(sendNext, delay * 1000);
        }
    };
    socket.onerror = fail;
    socket.onclose = (event) => {
        stop();
        onClose(event);
    };

    return {
        cancel() {
            stop();
            socket.close();
        },
        dispose() {
            stop();
            socket.onopen = null;
            socket.onmessage = null;
            socket.onerror = null;
            socket.onclose = null;
            socket.close();
        },
    };
}
