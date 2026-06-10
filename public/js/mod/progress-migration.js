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

    const localProgress = Number.parseInt(progress, 10);
    const storedServerProgress = Number.parseInt(serverProgress, 10);

    return Number.isFinite(localProgress) && Number.isFinite(storedServerProgress) && localProgress > storedServerProgress;
}
