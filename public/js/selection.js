// Bulk-selection state module for the index page.
// In-memory only; clears on page reload.
const Selection = {};
Selection._set = new Set();
Selection._observers = [];

Selection.has = function (id) { return Selection._set.has(id); };
Selection.size = function () { return Selection._set.size; };
Selection.ids = function () { return Array.from(Selection._set); };

Selection.add = function (id) {
    if (!id) return;
    if (Selection._set.has(id)) return;
    Selection._set.add(id);
    Selection._notify();
};

Selection.remove = function (id) {
    if (!Selection._set.delete(id)) return;
    Selection._notify();
};

Selection.toggle = function (id) {
    if (Selection._set.has(id)) Selection._set.delete(id);
    else Selection._set.add(id);
    Selection._notify();
};

Selection.clear = function () {
    if (Selection._set.size === 0) return;
    Selection._set.clear();
    Selection._notify();
};

Selection.onChange = function (cb) {
    Selection._observers.push(cb);
};

Selection._notify = function () {
    const { size } = Selection._set;
    for (let i = 0; i < Selection._observers.length; i++) {
        // eslint-disable-next-line no-console
        try { Selection._observers[i](size); } catch (err) { console.error(err); }
    }
};
