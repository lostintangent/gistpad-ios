import { Component, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import ReactMarkdown, { type Components, type Options } from "react-markdown";
import remarkGfm from "remark-gfm";
import remarkGithubAlerts from "remark-github-alerts";
import remarkFrontmatter from "remark-frontmatter";
import rehypeRaw from "rehype-raw";
import rehypeSlug from "rehype-slug";
import rehypeSanitize, { defaultSchema } from "rehype-sanitize";
import emojiData from "@emoji-mart/data/sets/15/native.json";
import remarkInlineSyntax from "../../../../gistpad.dev/src/features/markdown/remarkInlineSyntax";
import rehypeToc from "@gistpad/rehype-toc";
import Mermaid from "../../../../gistpad.dev/src/features/markdown/Mermaid";
import { taskRangePlugins } from "./tasks";
import { toString } from "hast-util-to-string";
import type { PreviewMessage, RenderRequest, TaskEdit } from "./protocol";
import { CommentText, type CommentHighlightController } from "./commentHighlights";

const emojis = new Map(
  Object.entries(emojiData.emojis).map(([id, emoji]) => [id, emoji.skins[0]?.native ?? ""]),
);
const schema = {
  ...defaultSchema,
  clobberPrefix: "",
  attributes: {
    ...defaultSchema.attributes,
    a: [...(defaultSchema.attributes?.a ?? []), "dataWikilink", "dataBookmark"],
    span: [...(defaultSchema.attributes?.span ?? []), "dataSpoiler", "className"],
    div: [...(defaultSchema.attributes?.div ?? []), "className"],
    blockquote: [...(defaultSchema.attributes?.blockquote ?? []), "className"],
    p: [...(defaultSchema.attributes?.p ?? []), ["className", "markdown-alert-title"]],
    svg: ["viewBox", "width", "height", "fill", "ariaHidden"],
    path: ["d"],
  },
  tagNames: [...(defaultSchema.tagNames ?? []), "svg", "path"],
  protocols: {
    ...defaultSchema.protocols,
    src: ["https", "http", "data"],
  },
};

export function send(message: PreviewMessage) {
  window.webkit?.messageHandlers?.gistpadPreview?.postMessage(message);
}

function Spoiler({ children }: { children: ReactNode }) {
  const [revealed, setRevealed] = useState(false);
  const ref = useRef<HTMLSpanElement>(null);
  useEffect(() => {
    const reveal = () => setRevealed(true);
    const spoiler = ref.current!;
    spoiler.addEventListener("gistpad-reveal-comment", reveal);
    return () => spoiler.removeEventListener("gistpad-reveal-comment", reveal);
  }, []);
  return (
    <span ref={ref} className="spoiler">
      <button className="spoiler-toggle" aria-expanded={revealed}
        aria-label={revealed ? "Hide spoiler" : "Reveal spoiler"} onClick={() => setRevealed(!revealed)}>
        {revealed ? <svg aria-hidden="true" viewBox="0 0 24 24" width="16" height="16"
          fill="none" stroke="currentColor" strokeWidth="1.5">
          <path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7S2 12 2 12Z" />
          <circle cx="12" cy="12" r="3" /><path d="m3 3 18 18" />
        </svg> : "Reveal spoiler"}
      </button>
      <span hidden={!revealed}>{children}</span>
    </span>
  );
}

type AlertKind = "note" | "tip" | "important" | "warning" | "caution";
function isAlertKind(value: string): value is AlertKind {
  return ["note", "tip", "important", "warning", "caution"].includes(value);
}

function AlertSymbol({ kind }: { kind: AlertKind }) {
  const outline = (() => {
    switch (kind) {
      case "note": return <circle cx="12" cy="12" r="9" />;
      case "tip": return <path d="M9 18h6m-5 3h4M9 15c0-2-4-3-4-7a7 7 0 0 1 14 0c0 4-4 5-4 7v1H9Z" />;
      case "important": return <path d="m12 2 10 10-10 10L2 12Z" />;
      case "warning": return <path d="m12 3 10 18H2Z" />;
      case "caution": return <path d="M8 2h8l6 6v8l-6 6H8l-6-6V8Z" />;
    }
  })();
  return <svg className="alert-symbol" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    {outline}
    {kind === "note"
      ? <><path d="M12 10v7" /><path d="M12 7h.01" /></>
      : kind === "tip" ? null : <><path d="M12 8v5" /><path d="M12 17h.01" /></>}
  </svg>;
}

export class PreviewErrorBoundary extends Component<
  { request: RenderRequest; children: ReactNode },
  { error: boolean }
> {
  state = { error: false };
  static getDerivedStateFromError() {
    return { error: true };
  }
  componentDidCatch(error: Error) {
    send({ ...identity(this.props.request), type: "failure", message: error.message.slice(0, 512) });
  }
  componentDidUpdate(previous: { request: RenderRequest }) {
    if (this.state.error && previous.request.generation !== this.props.request.generation) {
      this.setState({ error: false });
    }
  }
  render() {
    return this.state.error ? <p role="alert">This preview could not be rendered.</p> : this.props.children;
  }
}

export function identity(request: RenderRequest) {
  return { documentID: request.documentID, generation: request.generation };
}

export function Preview({ request, comments }: { request: RenderRequest; comments: CommentHighlightController }) {
  const taskPlugins = useMemo(() => taskRangePlugins(request.markdown), [request]);
  const contents = useRef({ documentID: request.documentID, open: false });
  if (contents.current.documentID !== request.documentID) {
    contents.current = { documentID: request.documentID, open: false };
  }
  const components = useMemo<Components>(() => {
    const link = (kind: "external" | "wikilink" | "anchor", target: string) => {
      if (kind === "anchor") {
        const element = document.getElementById(target);
        element?.scrollIntoView({ block: "start" });
        element?.setAttribute("tabindex", "-1");
        element?.focus({ preventScroll: true });
      }
      send({ ...identity(request), type: "link", kind, target });
    };
    return {
      div({ children, className, node: _, ...props }) {
        return className?.split(" ").includes("markdown-toc")
          ? <details className="markdown-toc" open={contents.current.open}
            onToggle={(event) => { contents.current.open = event.currentTarget.open; }}>
            <summary>Contents</summary>
            <nav aria-label="Contents">{children}</nav>
          </details>
          : <div {...props} className={className}>{children}</div>;
      },
      li({ style, node: _, ...props }) {
        const depth = typeof style?.marginLeft === "string" ? /^([0-5])rem$/.exec(style.marginLeft)?.[1] : undefined;
        return depth === undefined
          ? <li {...props} style={style} />
          : <li {...props} style={{ ...style, marginLeft: 0, paddingInlineStart: `${Number(depth) * 12}px` }} />;
      },
      a({ href, children, node, ...props }) {
        const wikilink = node?.properties.dataWikilink;
        const bookmark = node?.properties.dataBookmark;
        if (typeof wikilink === "string") {
          return <button className="wikilink" onClick={() => link("wikilink", wikilink)}>{children}</button>;
        }
        if (typeof bookmark === "string") {
          return <button id={bookmark} className="bookmark" aria-label={`Bookmark ${bookmark}`} onClick={() => link("anchor", bookmark)}>♧</button>;
        }
        if (!href) return <span>{children}</span>;
        return (
          <a {...props} href={href} onClick={(event) => {
            event.preventDefault();
            link(href.startsWith("#") ? "anchor" : "external", href.startsWith("#") ? href.slice(1) : href);
          }}>{children}</a>
        );
      },
      span({ children, node, ...props }) {
        const segment = comments.segment(node);
        if (segment !== undefined) {
          return <CommentText controller={comments} segment={segment} text={toString(node!)} />;
        }
        if (props.className?.split(" ").includes("octicon")) return null;
        const resultKind = props.className?.split(" ").includes("bg-amber-500")
          ? "current" : props.className?.split(" ").includes("bg-green-500") ? "previous" : undefined;
        if (resultKind) {
          const value = node ? toString(node) : "";
          return <span {...props} className={`calculation-result calculation-${resultKind}`}
            role="math" aria-label={`${resultKind === "current" ? "Current" : "Previous"} result: ${value}`}>
            {children}
          </span>;
        }
        return node?.properties.dataSpoiler !== undefined
          ? <Spoiler>{children}</Spoiler>
          : <span {...props}>{children}</span>;
      },
      input({ node, checked, type }) {
        if (type !== "checkbox") return null;
        const location = node?.properties.dataTaskLocation;
        const expectedMarker = node?.properties.dataTaskExpected;
        const replacementMarker = node?.properties.dataTaskReplacement;
        const addressable = typeof location === "number" &&
          (expectedMarker === "[ ]" || expectedMarker === "[x]" || expectedMarker === "[X]") &&
          (replacementMarker === "[ ]" || replacementMarker === "[x]");
        const edit: TaskEdit | undefined = addressable
          ? { location, length: 3, expectedMarker, replacementMarker } : undefined;
        return <TaskCheckbox checked={!!checked} label={String(node?.properties.dataTaskLabel ?? "Task")}
          edit={edit} request={request} />;
      },
      pre({ children, node, ...props }) {
        const isDiagram = node?.children.some((child) => child.type === "element" &&
          child.tagName === "code" && String(child.properties.className).includes("language-mermaid"));
        return isDiagram ? children : <pre {...props}>{children}</pre>;
      },
      code({ children, className, node: _, ...props }) {
        if (className === "language-mermaid") {
          return <NativeDiagram content={String(children).trim()} />;
        }
        if (className === "language-tldraw") {
          return <span className="unsupported">Whiteboards are not supported in GistPad Native.</span>;
        }
        return <code {...props} className={className}>{children}</code>;
      },
      table({ node: _, ...props }) {
        return <div className="table-scroll"><table {...props} /></div>;
      },
      p({ children, className, node, ...props }) {
        const isAlertTitle = className?.split(" ").includes("markdown-alert-title");
        const kind = node ? toString(node).trim().toLowerCase() : "";
        return <p {...props} className={className} dir="auto">
          {isAlertTitle && isAlertKind(kind) && <AlertSymbol kind={kind} />}
          {children}
        </p>;
      },
      img({ src, alt }) {
        return <PreviewImage src={typeof src === "string" ? src : undefined} alt={alt ?? ""} />;
      },
    };
  }, [request, comments]);
  const remarkPlugins: Options["remarkPlugins"] = [
    remarkGfm, remarkGithubAlerts, remarkFrontmatter, taskPlugins.remark,
    [remarkInlineSyntax, { emojis }],
  ];
  const rehypePlugins: Options["rehypePlugins"] = [
    rehypeRaw, [rehypeSanitize, schema], rehypeSlug, rehypeToc, taskPlugins.rehype,
    comments.catalogPlugin,
  ];

  useEffect(() => {
    send({ ...identity(request), type: "rendered" });
  }, [request]);

  return <article className="prose markdown-container" dir="auto">
    <ReactMarkdown remarkPlugins={remarkPlugins} rehypePlugins={rehypePlugins} components={components}
      urlTransform={(url) => /^(?:https?:|mailto:|#)/i.test(url) || url.startsWith("data:image/png;base64,") ? url : ""}>
      {request.markdown}
    </ReactMarkdown>
  </article>;
}

function TaskCheckbox({ checked, label, edit, request }: {
  checked: boolean; label: string; edit?: TaskEdit; request: RenderRequest;
}) {
  const editable = request.allowsTaskEdits ? edit : undefined;
  const action = !request.allowsTaskEdits ? "Read-only task" : edit === undefined ? "Unavailable task"
    : checked ? "Mark incomplete" : "Mark complete";
  return <label className="task-toggle"><input type="checkbox" checked={checked} disabled={!editable}
    aria-label={`${action}: ${label}`}
    onChange={() => editable && send({ ...identity(request), type: "taskToggle", edit: editable })} /></label>;
}

function PreviewImage({ src, alt }: { src?: string; alt: string }) {
  const [failed, setFailed] = useState(false);
  useEffect(() => setFailed(false), [src]);
  return src && !failed
    ? <img src={src} alt={alt} loading="lazy" referrerPolicy="no-referrer" onError={() => setFailed(true)} />
    : <span className="image-unavailable" role="img" aria-label={alt || "Image"}>{alt || "Image"} · unavailable offline</span>;
}

function NativeDiagram({ content }: { content: string }) {
  const container = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const updateScale = () => {
      const svg = container.current?.querySelector("svg");
      if (!svg?.viewBox.baseVal.width) return;
      const bodySize = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--gp-body-size"));
      svg.style.width = `${svg.viewBox.baseVal.width * bodySize / 16}px`;
      svg.style.maxWidth = "none";
    };
    const observer = new MutationObserver(updateScale);
    observer.observe(container.current!, { childList: true, subtree: true });
    window.addEventListener("gistpad-preview-appearance", updateScale);
    updateScale();
    return () => {
      observer.disconnect();
      window.removeEventListener("gistpad-preview-appearance", updateScale);
    };
  }, []);
  return <div ref={container} className="diagram-scroll" role="figure" aria-label="Mermaid diagram" tabIndex={0}>
    <Mermaid content={content} onExpand={() => container.current?.focus()} />
  </div>;
}
