async (page) => {
  const base = "http://127.0.0.1:4179";
  await page.route("**/*", (route) =>
    route.request().url().startsWith(base) ? route.continue() : route.abort("internetdisconnected"));
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto(`${base}/Web/index.html`);
  await page.setViewportSize({ width: 402, height: 874 });
  const markdown = [
    "# Comment notebook",
    "",
    "A quiet native note, with **careful** words and [a useful link](https://gistpad.dev).",
    "",
    "`quiet native` stays code.",
    "",
    "```text",
    "native note",
    "```",
    "",
    "| Item | State |",
    "| --- | --- |",
    "| Notebook | Readable |",
    "",
    '<span class="comment-highlight comment-selected" data-comment-ids="999">An authored lookalike</span>',
  ].join("\n");
  await page.evaluate((markdown) => {
    window.commentEvents = [];
    window.previewMessages = [];
    window.addEventListener("gistpad-comment-message", (event) => window.commentEvents.push(event.detail));
    window.addEventListener("gistpad-preview-message", (event) => window.previewMessages.push(event.detail));
    window.gistpadPreview.render({
      version: 1, documentID: "comments", generation: "18446744073709551615", markdown,
    });
  }, markdown);
  await page.waitForFunction(() => window.previewMessages.some((message) => message.type === "rendered"));
  const catalog = await page.evaluate(() => window.gistpadPreview.commentSegments());
  if (catalog.segments.includes("quiet native") || catalog.segments.includes("native note") ||
      !catalog.segments.includes("careful")) {
    throw new Error("Code exclusion or formatted text-node segmentation changed.");
  }
  const body = catalog.segments.indexOf("A quiet native note, with ");
  const link = catalog.segments.indexOf("a useful link");
  if (body < 0 || link < 0) throw new Error("Expected rendered text nodes are missing.");
  const highlights = [
    { segment: body, start: 2, end: 8, commentIDs: ["10"] },
    { segment: body, start: 8, end: 14, commentIDs: ["10", "20"] },
    { segment: body, start: 14, end: 19, commentIDs: ["20"] },
    { segment: link, start: 0, end: 13, commentIDs: ["9223372036854775807"] },
  ];
  const results = [];
  for (const dark of [false, true]) {
    for (const increased of [false, true]) {
      await page.emulateMedia({ colorScheme: dark ? "dark" : "light", reducedMotion: "reduce" });
      await page.evaluate(({ dark, increased }) => {
        const root = document.documentElement;
        root.dataset.contrast = increased ? "increased" : "normal";
        root.style.colorScheme = dark ? "dark" : "light";
        for (const [name, value] of Object.entries({
          page: dark ? "#000000" : "#FFFFFF",
          text: dark ? "#FFFFFF" : "#000000",
          link: dark ? "#0A84FF" : "#007AFF",
          surface: dark ? "#1C1C1E" : "#F2F2F7",
          "accent-fill": "#FACC15", "on-accent": "#000000",
        })) root.style.setProperty(`--gp-${name}`, value);
        window.dispatchEvent(new Event("gistpad-preview-appearance"));
        window.gistpadPreview.setCommentHighlights({
          version: 1, documentID: "comments", generation: "18446744073709551615",
          highlights: [], selectedCommentID: null, showsInlineComments: true, allowsInteraction: true, accent: "#FACC15",
        });
        const paragraph = document.querySelector("article > p");
        const leaf = paragraph.querySelector(".comment-text").firstChild;
        const range = document.createRange();
        range.setStart(leaf, 2);
        range.setEnd(leaf, 19);
        const selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
        window.commentParagraph = paragraph;
        window.commentOriginalText = document.querySelector("article").textContent;
        window.commentOriginalRect = range.getBoundingClientRect().toJSON();
      }, { dark, increased });
      await page.evaluate((highlights) => window.gistpadPreview.setCommentHighlights({
        version: 1, documentID: "comments", generation: "18446744073709551615",
        highlights, selectedCommentID: null, showsInlineComments: true, allowsInteraction: true, accent: "#FACC15",
      }), highlights);
      await page.waitForFunction(() => document.querySelectorAll(".comment-highlight[data-comment-ids]").length === 4);
      const check = await page.evaluate(() => {
        const selection = window.getSelection();
        const rect = selection.getRangeAt(0).getBoundingClientRect();
        const before = window.commentOriginalRect;
        const spoof = document.querySelector('.comment-highlight:not([data-comment-ids])');
        return {
          selection: selection.toString(),
          sameParagraph: document.querySelector("article > p") === window.commentParagraph,
          sameText: document.querySelector("article").textContent === window.commentOriginalText,
          sameGeometry: ["x", "y", "width", "height"].every((key) => Math.abs(before[key] - rect[key]) < 0.1),
          validTables: !document.querySelector("table > span, thead > span, tbody > span, tr > span"),
          noAuthoredAnnotation: spoof && getComputedStyle(spoof).backgroundColor === "rgba(0, 0, 0, 0)",
          bodyFill: getComputedStyle(document.querySelector('[data-comment-ids="10"]')).backgroundColor,
          linkFill: getComputedStyle(document.querySelector('[data-comment-ids="9223372036854775807"]')).backgroundColor,
          exactSelectionSnapshot: JSON.stringify(window.gistpadPreview.commentSelection()) === JSON.stringify({
            version: 1, documentID: "comments", generation: "18446744073709551615", quote: "quiet native note",
          }),
          accessibleQuoteText: [...document.querySelectorAll(".comment-highlight[data-comment-ids]")].every(
            (span) => span.getAttribute("aria-label") === span.textContent),
          readableFills: [...document.querySelectorAll(".comment-highlight[data-comment-ids]")].every((span) => {
            const channels = (color) => color.trim().startsWith("#")
              ? [1, 3, 5].map((start) => parseInt(color.trim().slice(start, start + 2), 16))
              : color.match(/[\d.]+/g).slice(0, 3).map(Number);
            const luminance = (rgb) => rgb.map((channel) => {
              const value = channel / 255;
              return value <= .04045 ? value / 12.92 : ((value + .055) / 1.055) ** 2.4;
            }).reduce((sum, value, index) => sum + value * [.2126, .7152, .0722][index], 0);
            const contrast = (a, b) => (Math.max(luminance(a), luminance(b)) + .05) /
              (Math.min(luminance(a), luminance(b)) + .05);
            const style = getComputedStyle(span);
            const page = channels(getComputedStyle(document.documentElement).getPropertyValue("--gp-page"));
            const ink = channels(style.color);
            const fill = channels(style.backgroundColor);
            const target = document.documentElement.dataset.contrast === "increased" ? 7 : 4.5;
            return contrast(ink, fill) + .000001 >= Math.min(target, contrast(ink, page));
          }),
        };
      });
      if (check.selection !== "quiet native note" ||
          !check.sameParagraph || !check.sameText || !check.sameGeometry ||
          !check.validTables || !check.noAuthoredAnnotation || !check.exactSelectionSnapshot ||
          !check.accessibleQuoteText || !check.readableFills) {
        throw new Error(`Comment updates changed source, selection, geometry or trusted annotation ownership: ${JSON.stringify(check)}`);
      }
      const backward = await page.evaluate((highlights) => {
        const selection = window.getSelection();
        selection.setBaseAndExtent(selection.focusNode, selection.focusOffset, selection.anchorNode, selection.anchorOffset);
        const state = {
          version: 1, documentID: "comments", generation: "18446744073709551615",
          selectedCommentID: null, showsInlineComments: true, allowsInteraction: true, accent: "#FACC15",
        };
        window.gistpadPreview.setCommentHighlights({ ...state, highlights: [] });
        window.gistpadPreview.setCommentHighlights({ ...state, highlights });
        return window.gistpadPreview.commentSelection().quote === "quiet native note" &&
          !!(selection.focusNode.compareDocumentPosition(selection.anchorNode) & Node.DOCUMENT_POSITION_FOLLOWING);
      }, highlights);
      if (!backward) throw new Error("Annotation updates changed a backward rendered selection.");
      await page.locator('[data-comment-ids="10 20"]').click();
      await page.locator('[data-comment-ids="10 20"]').focus();
      await page.keyboard.press("Space");
      const activations = await page.evaluate(() => window.commentEvents.slice(-2));
      if (activations.length !== 2 || activations.some((event) =>
        event.type !== "commentActivate" || event.segment !== body || event.start !== 8 || event.end !== 14 ||
        event.generation !== "18446744073709551615" || "commentIDs" in event)) {
        throw new Error(`Overlap activation lost its validated native range: ${JSON.stringify(activations)}`);
      }
      await page.evaluate((highlights) => window.gistpadPreview.setCommentHighlights({
        version: 1, documentID: "comments", generation: "18446744073709551615",
        highlights, selectedCommentID: "20", showsInlineComments: false, allowsInteraction: true, accent: "#FACC15",
      }), highlights);
      await page.waitForFunction(() =>
        document.querySelectorAll(".comment-highlight[data-comment-ids]").length === 2);
      const selected = await page.evaluate(() => [...document.querySelectorAll(".comment-highlight[data-comment-ids]")].every((span) => {
        const style = getComputedStyle(span);
        return span.getAttribute("aria-current") === "true" && !span.hasAttribute("aria-pressed") &&
          span.getAttribute("aria-description").startsWith("Selected comment. ") &&
          style.backgroundColor === "rgb(250, 204, 21)" && style.color === "rgb(0, 0, 0)" &&
          style.textDecorationLine.includes("underline");
      }));
      if (!selected) throw new Error("Selected-only annotations lost native accent or accessible state.");
      results.push({ dark, increased, ...check });
    }
  }
  await page.evaluate(() => window.gistpadPreview.render({
    version: 1, documentID: "hidden-comments", generation: "2",
    markdown: "<details><summary>A tucked thought</summary><p>A tucked native passage.</p></details>\n\n"
      + "A spoiler: >!A secret native passage.!<",
  }));
  await page.waitForFunction(() => window.previewMessages.some((message) =>
    message.type === "rendered" && message.documentID === "hidden-comments"));
  const hidden = await page.evaluate(() => {
    const catalog = window.gistpadPreview.commentSegments();
    const passages = ["tucked native passage", "secret native passage"];
    return passages.map((quote, index) => {
      const segment = catalog.segments.findIndex((text) => text.includes(quote));
      if (segment < 0) throw new Error(`Hidden passage is missing from the catalog: ${quote}`);
      const start = catalog.segments[segment].indexOf(quote);
      return { segment, start, end: start + quote.length, commentIDs: [String(310 + index * 10)] };
    });
  });
  for (const id of ["310", "320"]) {
    await page.evaluate(({ hidden, id }) => window.gistpadPreview.setCommentHighlights({
      version: 1, documentID: "hidden-comments", generation: "2", highlights: hidden,
      selectedCommentID: id, showsInlineComments: false, allowsInteraction: true, accent: "#FACC15",
    }), { hidden, id });
    await page.locator(`.comment-selected[data-comment-ids="${id}"]`).waitFor({ state: "visible" });
  }
  const disclosure = await page.evaluate(() =>
    document.querySelector("details").open && !!document.querySelector('.spoiler button[aria-expanded="true"]') &&
    !document.querySelector("button .comment-highlight[role=button]"));
  if (!disclosure) throw new Error("Selected comments failed to reveal hidden passages without nested buttons.");
  await page.getByRole("button", { name: "Hide spoiler", exact: true }).click();
  if (await page.locator('[data-comment-ids="320"]').isVisible()) throw new Error("Spoilers can no longer be concealed.");
  await page.getByRole("button", { name: "Reveal spoiler", exact: true }).click();
  await page.locator('[data-comment-ids="320"]').waitFor({ state: "visible" });

  const longText = "cafe\u0301 🫧 " + "native ".repeat(4_000) + "tail";
  await page.evaluate((markdown) => window.gistpadPreview.render({
    version: 1, documentID: "long-comment", generation: "3", markdown,
  }), longText);
  await page.waitForFunction(() => window.previewMessages.some((message) =>
    message.type === "rendered" && message.documentID === "long-comment"));
  const longSelection = await page.evaluate((text) => {
    const catalog = window.gistpadPreview.commentSegments();
    const selection = window.getSelection();
    selection.selectAllChildren(document.body);
    const snapshot = window.gistpadPreview.commentSelection();
    const exact = catalog.segments.length === 1 && catalog.segments[0] === text &&
      snapshot.quote === selection.toString() && snapshot.quote.includes(text) &&
      snapshot.documentID === "long-comment" && snapshot.generation === "3";
    selection.removeAllRanges();
    return exact && window.gistpadPreview.commentSelection().quote === null;
  }, longText);
  if (!longSelection) throw new Error("Long rendered selections were chunked, truncated or normalized.");
  const reveal = {
    version: 1, documentID: "long-comment", generation: "3",
    highlights: [{ segment: 0, start: longText.length - 4, end: longText.length, commentIDs: ["40"] }],
    selectedCommentID: "40", revealRevision: "1",
    showsInlineComments: true, allowsInteraction: true, accent: "#FACC15",
  };
  const selectedIsVisible = () => {
    const rect = document.querySelector(".comment-selected")?.getBoundingClientRect();
    return rect && rect.top >= 0 && rect.bottom <= window.innerHeight;
  };
  await page.evaluate((reveal) => window.gistpadPreview.setCommentHighlights(reveal), reveal);
  await page.waitForFunction(selectedIsVisible);
  await page.evaluate((reveal) => {
    window.scrollTo(0, 0);
    window.gistpadPreview.setCommentHighlights(reveal);
  }, reveal);
  if (await page.evaluate(selectedIsVisible)) throw new Error("An ordinary refresh unexpectedly repeated a quote jump.");
  await page.evaluate((reveal) => window.gistpadPreview.setCommentHighlights({
    ...reveal, revealRevision: "2",
  }), reveal);
  await page.waitForFunction(selectedIsVisible);
  if (errors.length || await page.evaluate(() => window.previewMessages.some((message) => message.type === "failure"))) {
    throw new Error(`Renderer errors: ${JSON.stringify(errors)}`);
  }
  return { pass: true, results };
}
