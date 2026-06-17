/**
 * Optional WebUI performance probes.
 *
 * Enable in the browser console with:
 * localStorage.lrrPerf = "1"; location.reload();
 */

let longTaskObserver = null;

function enabled() {
    return typeof localStorage !== "undefined" && localStorage.lrrPerf === "1";
}

function canMeasure() {
    return enabled() && typeof performance !== "undefined" && performance.mark && performance.measure;
}

export function initializeLongTaskObserver() {
    if (!enabled() || longTaskObserver !== null || typeof PerformanceObserver === "undefined") return;

    try {
        longTaskObserver = new PerformanceObserver((list) => {
            list.getEntries().forEach((entry) => {
                // eslint-disable-next-line no-console
                console.debug("[LRR perf] longtask", {
                    name: entry.name,
                    startTime: Math.round(entry.startTime * 100) / 100,
                    duration: Math.round(entry.duration * 100) / 100,
                });
            });
        });
        longTaskObserver.observe({ entryTypes: ["longtask"] });
    } catch {
        longTaskObserver = null;
    }
}

export function measure(name, fn) {
    if (!canMeasure()) return fn();

    const marker = `${name}:${performance.now()}`;
    const start = `${marker}:start`;
    const end = `${marker}:end`;
    performance.mark(start);

    const finish = () => {
        performance.mark(end);
        performance.measure(name, start, end);
        const entries = performance.getEntriesByName(name);
        const latest = entries[entries.length - 1];
        if (latest) {
            // eslint-disable-next-line no-console
            console.debug("[LRR perf]", name, `${Math.round(latest.duration * 100) / 100}ms`);
        }
        performance.clearMarks(start);
        performance.clearMarks(end);
    };

    try {
        const result = fn();
        if (result && typeof result.finally === "function") {
            return result.finally(finish);
        }
        finish();
        return result;
    } catch (e) {
        finish();
        throw e;
    }
}
