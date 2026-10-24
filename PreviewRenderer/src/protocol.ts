export const protocolVersion = 1;
export const maximumDocumentLength = 2 * 1024 * 1024;

export interface RenderRequest {
  version: 1;
  documentID: string;
  generation: string;
  markdown: string;
}

export interface TaskEdit {
  location: number;
  length: 3;
  expectedMarker: "[ ]" | "[x]" | "[X]";
  replacementMarker: "[ ]" | "[x]";
}

export type PreviewMessage =
  | { type: "ready"; version: 1 }
  | (Pick<RenderRequest, "documentID" | "generation" | "version"> &
      (
        | { type: "taskToggle"; edit: TaskEdit }
        | { type: "link"; kind: "external" | "wikilink" | "anchor"; target: string }
        | { type: "height"; height: number }
        | { type: "rendered" }
        | { type: "failure"; message: string }
      ));

export function isRenderRequest(value: unknown): value is RenderRequest {
  if (!value || typeof value !== "object") return false;
  const data = value as Partial<RenderRequest>;
  return (
    data.version === protocolVersion &&
    typeof data.documentID === "string" &&
    data.documentID.length > 0 &&
    data.documentID.length <= 512 &&
    typeof data.generation === "string" &&
    /^(0|[1-9]\d{0,19})$/.test(data.generation) &&
    BigInt(data.generation) <= 18_446_744_073_709_551_615n &&
    typeof data.markdown === "string" &&
    data.markdown.length <= maximumDocumentLength
  );
}

declare global {
  interface Window {
    gistpadPreview: { render: (request: unknown) => void; setAppearance: (appearance: unknown) => void };
    webkit?: {
      messageHandlers?: { gistpadPreview?: { postMessage: (message: PreviewMessage) => void } };
    };
  }
}
