/**
 * Latest-only, ordered progress write queue.
 *
 * Reader navigation can enqueue a final completion value while an earlier page
 * update is still in flight. Keep one active request per archive and retain
 * only the newest pending value so an older write cannot run after the final
 * value. The transport is injected to keep this small state machine
 * browser-independent and directly testable under node.
 */

export const DEFAULT_PROGRESS_RETRY_COUNT = 3;
export const DEFAULT_PROGRESS_RETRY_DELAY_MS = 50;

function deferred() {
    let resolve;
    let reject;
    const promise = new Promise((resolvePromise, rejectPromise) => {
        resolve = resolvePromise;
        reject = rejectPromise;
    });
    return { promise, resolve, reject };
}

/**
 * @param {object} options
 * @param {(request: object) => Promise<object>} options.send transport callback
 * @param {(delayMs: number) => Promise<void>} [options.wait] retry delay
 * @param {number} [options.retryCount] maximum retries after HTTP 423
 * @param {number} [options.retryDelayMs] delay between retries
 */
export function createProgressWriteQueue({
    send,
    wait = (delayMs) => new Promise((resolve) => setTimeout(resolve, delayMs)),
    retryCount = DEFAULT_PROGRESS_RETRY_COUNT,
    retryDelayMs = DEFAULT_PROGRESS_RETRY_DELAY_MS,
} = {}) {
    if (typeof send !== "function") {
        throw new TypeError("Progress write queue requires a send function");
    }

    const queues = new Map();
    const maxRetries = Math.max(0, Math.trunc(Number(retryCount)) || 0);
    const retryDelay = Math.max(0, Number(retryDelayMs) || 0);

    async function sendWithRetry(request, queue) {
        let retries = 0;
        const transportRequest = {
            key: request.key,
            endpoint: request.endpoint,
            page: request.page,
            keepalive: request.keepalive,
        };
        while (true) {
            const result = await send(transportRequest);
            if (result?.code !== 423) {
                return result;
            }
            if (queue.pending !== null) {
                // A newer value is waiting. A 423 means this request did not
                // mutate the server, so retrying it would only delay the
                // latest value (especially during pagehide).
                return { skipped: true };
            }
            if (retries >= maxRetries) {
                return result;
            }
            retries += 1;
            await wait(retryDelay);
        }
    }

    async function drain(key, queue) {
        while (queue.pending !== null) {
            const request = queue.pending;
            queue.pending = null;

            try {
                request.deferred.resolve(await sendWithRetry(request, queue));
            } catch (error) {
                request.deferred.reject(error);
            }
        }

        queue.active = false;
        if (queue.pending === null) {
            queues.delete(key);
        }
    }

    function enqueue(key, page, { endpoint = key, keepalive = false } = {}) {
        const queue = queues.get(key) || { active: false, pending: null };
        const request = {
            key,
            endpoint,
            page,
            keepalive: Boolean(keepalive),
            deferred: deferred(),
        };

        if (queue.pending !== null) {
            // Intermediate navigation writes are intentionally superseded.
            // Resolve their callers so they do not become unhandled promises.
            queue.pending.deferred.resolve({ skipped: true });
        }
        queue.pending = request;
        queues.set(key, queue);

        if (!queue.active) {
            queue.active = true;
            drain(key, queue);
        }

        return request.deferred.promise;
    }

    return { enqueue };
}
