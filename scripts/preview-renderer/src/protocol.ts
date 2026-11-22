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
      ));

declare global {
  interface Window {
    gistpadPreview: {
      render: (request: RenderRequest) => void;
      setAppearance: (appearance: import("./appearance").Appearance) => void;
      setViewportInsets: (insets: import("./viewport").ViewportInsets) => void;
      commentSegments: () => unknown;
      commentSelection: () => unknown;
      setCommentHighlights: (value: import("./commentHighlights").HighlightState) => void;
    };
    webkit?: {
      messageHandlers?: {
        gistpadPreview?: { postMessage: (message: PreviewMessage) => void };
        gistpadComments?: { postMessage: (message: import("./commentHighlights").CommentThreadActivation) => void };
      };
    };
  }
}
