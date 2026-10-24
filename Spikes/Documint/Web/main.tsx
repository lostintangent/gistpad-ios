import { Documint, type DocumintStorage, type EditorTheme } from "@lostintangent/documint";
import { useLayoutEffect, useState } from "react";
import { createRoot } from "react-dom/client";

type DocumentPayload = { documentID: string; generation: string; markdown: string };
type Snapshot = DocumentPayload & { revision: number };
type Appearance = { dark: boolean; bodySize: number; text: string; muted: string;
  background: string; surface: string; border: string; blue: string;
  accentText: string; accentFill: string; onAccent: string };
type NativeMessage = Record<string, unknown> & { version: 1; type: string };
declare global {
  interface Window {
    webkit?: { messageHandlers?: { gistpadDocumint?: { postMessage(message: NativeMessage): void } } };
    gistpadDocumint: {
      setDocument(payload: DocumentPayload): void;
      setAppearance(payload: Appearance): void;
      acknowledge(revision: number, generation: string): void;
      snapshot(): DocumentPayload | null;
      flush(): boolean;
      metrics(): Record<string, unknown>;
    };
  }
}

let current: DocumentPayload | null = null;
let pending: string | null = null;
let inFlight: Snapshot | null = null;
let revision = 0;
let changes = 0;
let openedAt = 0;
let paintedAt = 0;
let showDocument: ((document: DocumentPayload) => void) | undefined;
let showAppearance: ((appearance: Appearance) => void) | undefined;
let showError: ((message: string) => void) | undefined;
const fallback: Appearance = {
  dark: false, bodySize: 17, text: "#000000", muted: "#666666", background: "#ffffff",
  surface: "#f2f2f7", border: "#c6c6c8", blue: "#007aff",
  accentText: "#0369a1", accentFill: "#0ea5e9", onAccent: "#000000",
};
const storage: DocumintStorage = {
  async readFile(path) {
    const filename = path.split("/").at(-1);
    if (filename !== "pixel.svg" && filename !== "pixel.png") {
      throw new Error("External images are disabled in this offline spike");
    }
    const response = await fetch(`./${filename}`);
    if (!response.ok) throw new Error("The bundled image is missing");
    return response.blob();
  },
  async writeFile() { throw new Error("Image uploads are not part of this spike"); },
};

function post(type: string, detail: Record<string, unknown> = {}) {
  window.webkit?.messageHandlers?.gistpadDocumint?.postMessage({ version: 1, type, ...detail });
}

function fail(message: string) {
  showError?.(message);
  post("failure", { message });
}

function sendPending() {
  if (!current || inFlight || pending === null) return;
  if (pending === current.markdown) { pending = null; return; }
  inFlight = { ...current, markdown: pending, revision: ++revision };
  pending = null;
  post("changed", inFlight);
}

window.gistpadDocumint = {
  setDocument(payload) {
    if (!payload || typeof payload.documentID !== "string" || !payload.documentID ||
      payload.documentID.length > 512 || typeof payload.generation !== "string" ||
      !/^\d+$/.test(payload.generation) ||
      typeof payload.markdown !== "string" || payload.markdown.length > 2 * 1024 * 1024) {
      throw new Error("Invalid native document");
    }
    if (current?.documentID === payload.documentID && current.generation === payload.generation) return;
    if (inFlight || pending !== null) throw new Error("Finish the pending rich edit before replacing its source");
    current = payload;
    openedAt = performance.now();
    paintedAt = 0;
    showDocument?.(payload);
  },
  setAppearance(payload) {
    if (!payload || typeof payload.dark !== "boolean" || !Number.isFinite(payload.bodySize) ||
      payload.bodySize < 8 || payload.bodySize > 100 ||
      [payload.text, payload.muted, payload.background, payload.surface, payload.border, payload.blue,
        payload.accentText, payload.accentFill, payload.onAccent]
        .some(value => typeof value !== "string" || !/^#[0-9a-f]{6}$/i.test(value))) {
      throw new Error("Invalid native theme");
    }
    document.documentElement.style.colorScheme = payload.dark ? "dark" : "light";
    document.body.style.backgroundColor = payload.background;
    showAppearance?.(payload);
  },
  acknowledge(ackRevision, generation) {
    if (!inFlight || ackRevision !== inFlight.revision || !/^\d+$/.test(generation)) {
      throw new Error("Invalid rich-edit acknowledgement");
    }
    current = { documentID: inFlight.documentID, markdown: inFlight.markdown, generation };
    inFlight = null;
    sendPending();
  },
  snapshot() {
    if (!current) return null;
    return { ...current, markdown: pending ?? inFlight?.markdown ?? current.markdown };
  },
  flush() { sendPending(); return !inFlight && pending === null; },
  metrics() {
    const input = document.querySelector<HTMLTextAreaElement>("textarea.documint-input");
    const canvas = document.querySelector("canvas.documint-content-canvas");
    const scroller = document.querySelector(".documint-scroll-container");
    return {
      changes, openToPaintMS: paintedAt ? paintedAt - openedAt : null,
      canvas: Boolean(canvas), semanticHeadings: document.querySelectorAll("h1,h2,h3").length,
      semanticTables: document.querySelectorAll("table").length,
      inputContextLength: input?.value.length ?? 0, spellcheck: input?.spellcheck,
      autocapitalize: input?.autocapitalize, inputFocused: document.activeElement === input,
      scrollHeight: scroller?.scrollHeight, viewportHeight: scroller?.clientHeight,
      pending: Boolean(inFlight || pending !== null),
    };
  },
};

function Editor() {
  const [source, setSource] = useState<DocumentPayload | null>(null);
  const [appearance, setAppearance] = useState(fallback);
  const [error, setError] = useState<string>();
  useLayoutEffect(() => {
    showDocument = setSource;
    showAppearance = setAppearance;
    showError = setError;
    post("ready");
    return () => { showDocument = undefined; showAppearance = undefined; showError = undefined; };
  }, []);
  useLayoutEffect(() => {
    if (!source || paintedAt) return;
    let secondFrame = 0;
    const firstFrame = requestAnimationFrame(() => {
      secondFrame = requestAnimationFrame(() => {
        paintedAt = performance.now();
        post("rendered", { documentID: source.documentID, generation: source.generation,
          milliseconds: paintedAt - openedAt });
      });
    });
    return () => { cancelAnimationFrame(firstFrame); cancelAnimationFrame(secondFrame); };
  }, [source?.documentID, source?.generation]);
  const theme: EditorTheme = {
    accent: appearance.blue, background: appearance.background, muted: appearance.muted,
    text: appearance.text, fontSize: appearance.bodySize, paddingX: 20, paddingY: 24,
    headingText: appearance.text, paragraphText: appearance.text,
    caret: appearance.blue, linkText: appearance.blue, listMarkerText: appearance.accentText,
    checkboxCheckedFill: appearance.accentFill, checkboxCheckmark: appearance.onAccent,
    checkboxUncheckedStroke: appearance.muted, leafAccent: appearance.text,
    leafButtonText: appearance.text, leafText: appearance.text, leafSecondaryText: appearance.muted,
    leafBackground: appearance.surface, leafBorder: appearance.border,
    codeBackground: appearance.surface, codeText: appearance.text,
    headingRule: appearance.border, tableBorder: appearance.border,
    tableHeaderBackground: appearance.surface, tableBodyBackground: appearance.background,
    dividerRule: appearance.border,
  };
  return <>
    {error && <p className="error" role="alert">{error}</p>}
    <div className="surface">
      {source && <Documint key={source.documentID} content={source.markdown} theme={theme}
        showDiffs={false}
        storage={storage}
        onContentChanged={(markdown) => {
          if (!current || markdown === (pending ?? inFlight?.markdown ?? current.markdown)) return;
          changes += 1;
          setSource({ ...current, markdown });
          pending = markdown;
          sendPending();
        }}
      />}
    </div>
  </>;
}

window.addEventListener("error", () => fail("The rich editor encountered a JavaScript error."));
window.addEventListener("unhandledrejection", () => fail("The rich editor could not finish an operation."));
createRoot(document.getElementById("root")!).render(<Editor />);
