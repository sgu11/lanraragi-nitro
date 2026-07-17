function parseProgressValue(value) {
    if (value === null || value === undefined) {
        return NaN;
    }

    const text = String(value).trim();
    return /^\d+$/.test(text) ? Number.parseInt(text, 10) : NaN;
}

export function shouldRunProgressMigration(isProgressLocal, isProgressAuthenticated, userLogged) {
    return !isProgressLocal && !(isProgressAuthenticated && !userLogged);
}

export function metadataResponseMeansMissing(response, data) {
    if (response.status === 404) {
        return true;
    }

    if (response.status !== 400 || data?.success !== 0 || typeof data.error !== "string") {
        return false;
    }

    return /\b(?:doesn(?:'|&#39;)t|does not) exist\b/i.test(data.error);
}

export function shouldMigrateProgressValue(progress, serverProgress) {
    if (progress === null || serverProgress === undefined || serverProgress === null) {
        return false;
    }

    const localProgress = parseProgressValue(progress);
    const storedServerProgress = parseProgressValue(serverProgress);

    return Number.isFinite(localProgress) && Number.isFinite(storedServerProgress) && localProgress > storedServerProgress;
}

/**
 * Convert persisted 1-indexed progress into the 0-indexed page that the Reader
 * will open. Unset, invalid, and completed progress all open the first page.
 */
export function getReaderIntentStartIndex(progress, pageCount) {
    const storedProgress = parseProgressValue(progress);
    const totalPages = parseProgressValue(pageCount);

    if (!Number.isFinite(storedProgress) || !Number.isFinite(totalPages)
        || storedProgress <= 0 || storedProgress >= totalPages) {
        return 0;
    }
    return storedProgress - 1;
}
