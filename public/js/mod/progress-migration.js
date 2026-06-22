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

    return /\b(?:doesn't|does not) exist\b/i.test(data.error);
}

export function shouldMigrateProgressValue(progress, serverProgress) {
    if (progress === null || serverProgress === undefined || serverProgress === null) {
        return false;
    }

    const localProgress = parseProgressValue(progress);
    const storedServerProgress = parseProgressValue(serverProgress);

    return Number.isFinite(localProgress) && Number.isFinite(storedServerProgress) && localProgress > storedServerProgress;
}
