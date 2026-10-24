import { createRoot } from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { Preview, PreviewErrorBoundary, send } from "./Preview";
import { isRenderRequest } from "./protocol";
import { setAppearance } from "./appearance";
import { setTaskEditingEnabled } from "./taskEditing";
import "../../../gistpad.dev/src/features/markdown/index.css";
import "./style.css";

const root = createRoot(document.getElementById("root")!);
const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
window.gistpadPreview = Object.freeze({
  setAppearance,
  setTaskEditingEnabled,
  render(request: unknown) {
    if (!isRenderRequest(request)) throw new TypeError("Invalid preview render request");
    root.render(
      <QueryClientProvider client={queryClient}>
        <PreviewErrorBoundary key={request.documentID} request={request}>
          <Preview request={request} />
        </PreviewErrorBoundary>
      </QueryClientProvider>,
    );
  },
});
send({ type: "ready", version: 1 });
