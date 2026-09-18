const archivePattern = /^[a-f0-9]{40}$/;
const tankPattern = /^TANK_[0-9]+$/;

export function validBatchSelection(ids) {
    return Array.isArray(ids)
        ? [...new Set(ids.filter((id) => typeof id === "string" && (archivePattern.test(id) || tankPattern.test(id))))]
        : [];
}

/** Superseded loads stop scheduling work and cannot publish into the new list. */
export function createBatchArchiveLoader({ request, publish, complete, failed, concurrency = 6 }) {
    let generation = 0;
    let controller;
    async function load(selection = null) {
        controller?.abort();
        controller = new AbortController();
        const { signal } = controller;
        generation += 1;
        const ownGeneration = generation;
        const current = () => ownGeneration === generation;
        const failures = [];
        async function pool(ids, fetchOne) {
            const results = new Array(ids.length);
            let next = 0;
            await Promise.all(Array.from({ length: Math.min(concurrency, ids.length) }, async () => {
                while (current() && next < ids.length) {
                    const index = next;
                    next += 1;
                    try {
                        results[index] = await fetchOne(ids[index]);
                    } catch (error) {
                        failures.push(error);
                    }
                }
            }));
            return results;
        }
        try {
            let archives;
            let checked;
            if (selection !== null) {
                const ids = validBatchSelection(selection);
                const tanks = await pool(ids.filter((id) => tankPattern.test(id)), (id) => request(`/api/tankoubons/${id}`, { signal }));
                if (!current()) return;
                const archiveIds = validBatchSelection([
                    ...ids.filter((id) => archivePattern.test(id)),
                    ...tanks.flatMap((tank) => Array.isArray(tank?.archives) ? tank.archives : []),
                ]).filter((id) => archivePattern.test(id));
                archives = await pool(archiveIds, (id) => request(`/api/archives/${id}/metadata`, { signal }));
                checked = new Set(archiveIds);
            } else {
                archives = await request("/api/archives", { signal });
                if (!current()) return;
                checked = new Set();
                try {
                    const ids = await request("/api/archives/untagged", { signal });
                    checked = new Set(validBatchSelection(ids));
                } catch (error) {
                    failures.push(error);
                }
            }
            if (!current()) return;
            const seen = new Set();
            const rows = (Array.isArray(archives) ? archives : []).filter((archive) => {
                if (!archive || !archivePattern.test(archive.arcid) || seen.has(archive.arcid)) return false;
                seen.add(archive.arcid);
                return true;
            });
            publish(rows, checked);
            if (failures.length) failed(failures[0]);
        } catch (error) {
            if (current()) failed(error);
        } finally {
            if (current()) complete();
        }
    }
    return { load, cancel: () => { generation += 1; controller?.abort(); } };
}
