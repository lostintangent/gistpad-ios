export interface RenderRequest {
  generation: number;
  markdown: string;
  allowsTaskEdits: boolean;
}

export type Identity = Pick<RenderRequest, "generation">;

export function identity(request: RenderRequest): Identity {
  return { generation: request.generation };
}

export type PreviewMessage =
  | { type: "ready" }
  | (Identity &
      (
        | { type: "taskToggle"; location: number }
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
      setCommentAnnotations: (value: import("./commentAnnotations").AnnotationState) => void;
    };
    webkit?: {
      messageHandlers?: {
        gistpadPreview?: { postMessage: (message: PreviewMessage) => void };
      };
    };
  }
}
