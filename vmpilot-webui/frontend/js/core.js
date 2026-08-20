// core.js — React binding via vendored UMD + htm (JSX-free, no build).
import htm from "/vendor/htm.module.js";

export const React = window.React;
export const { useState, useEffect, useRef, useCallback, useMemo } = React;
export const html = htm.bind(React.createElement);

export const out = (v) => v;