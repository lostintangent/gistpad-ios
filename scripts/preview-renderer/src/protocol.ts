export interface RenderRequest {
  fileID: string;
  generation: number;
  markdown: string;
  allowsTaskEdits: boolean;
}

export type Identity = Pick<RenderRequest, "fileID" | "generation">;

export function identity(request: RenderRequest): Identity {
  return { fileID: request.fileID, generation: request.generation };
}

export interface TaskEdit {
  location: number;
  length: 3;
  expectedMarker: "[ ]" | "[x]" | "[X]";
  replacementMarker: "[ ]" | "[x]";
}

export type PreviewMessage =
  | { type: "ready" }
  | (Identity &
      (
        | { type: "taskToggle"; edit: TaskEdit }
        | { type: "link"; kind: "external" | "wikilink"; target: string }
        | { type: "rendered" }
        | { type: "failure"; message: string }
        | { type: "commentActivate"; segment: number; start: number; end: number }
      ));

export function send(message: PreviewMessage) {
  window.webkit?.messageHandlers?.gistpadPreview?.postMessage(message);
}

declare global {
  interface Window {
    gistpadPreview: {
      render: (request: RenderRequest) => void;
      setAppearance: (appearance: import("./appearance").Appearance) => void;
      commentSegments: () => string[];
      commentSelection: () => string | null;
      setCommentHighlights: (value: import("./commentHighlights").HighlightState) => void;
    };
    webkit?: {
      messageHandlers?: {
        gistpadPreview?: { postMessage: (message: PreviewMessage) => void };
      };
    };
  }
}
