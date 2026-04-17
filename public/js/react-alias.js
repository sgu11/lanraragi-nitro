// Alias preact/compat as React for libraries that expect the global (e.g. react-toastify).
// Must load after compat.umd.js and before react-toastify.umd.js.
window.React = window.preactCompat;
window.react = window.preactCompat;
