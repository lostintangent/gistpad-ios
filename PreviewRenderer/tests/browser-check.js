async (page) => {
  const base = "http://127.0.0.1:4179";
  await page.route("**/*", (route) =>
    route.request().url().startsWith(base) ? route.continue() : route.abort("internetdisconnected"));
  const response = await page.request.get(`${base}/Fixtures/all-syntax.md`);
  if (!response.ok()) throw new Error("Synthetic fixture is missing");
  const markdown = await response.text();
  await page.goto(`${base}/Web/index.html`);
  await page.setViewportSize({ width: 402, height: 874 });
  await page.evaluate((markdown) => {
    window.previewMessages = [];
    window.addEventListener("gistpad-preview-message", (event) => window.previewMessages.push(event.detail));
    window.gistpadPreview.render({ version: 1, documentID: "all-syntax", generation: "1", markdown });
  }, markdown);
  await page.getByRole("heading", { name: "A quiet notebook", exact: true }).waitFor();
  await page.locator("svg[id^='mermaid-']").waitFor();
  const checkboxes = page.getByRole("checkbox");
  if (await checkboxes.count() !== 7) throw new Error("Expected seven addressable tasks");
  if (await checkboxes.nth(1).isDisabled()) throw new Error("Duplicate task is not addressable");
  await page.evaluate(() => {
    const paragraph = document.querySelector("article > p");
    const range = document.createRange();
    range.selectNodeContents(paragraph);
    const selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
    window.previewSelectedText = selection.toString();
    window.previewParagraph = paragraph;
    window.gistpadPreview.setTaskEditingEnabled(false);
  });
  await page.waitForFunction(() => [...document.querySelectorAll("input[type=checkbox]")].every((input) => input.disabled));
  const readOnly = await page.evaluate(() => {
    const before = window.previewMessages.length;
    document.querySelectorAll("input[type=checkbox]")[1].click();
    return window.previewMessages.length === before &&
      !window.previewMessages.some((message) => message.type === "taskToggle" || message.type === "failure") &&
      [...document.querySelectorAll("input[type=checkbox]")].every((input) =>
        input.getAttribute("aria-label").startsWith("Read-only task: ") &&
        getComputedStyle(input).opacity === "1" &&
        getComputedStyle(input.closest("li")).opacity === "1") &&
      document.querySelector("article > p") === window.previewParagraph &&
      window.getSelection().toString() === window.previewSelectedText;
  });
  if (!readOnly) throw new Error("Read-only task controls changed selection, dimmed text or emitted an edit");
  await page.evaluate(() => {
    window.getSelection().removeAllRanges();
    window.gistpadPreview.setTaskEditingEnabled(true);
  });
  await page.waitForFunction(() => !document.querySelectorAll("input[type=checkbox]")[1].disabled);
  await checkboxes.nth(1).click();
  const toggle = await page.evaluate(() => window.previewMessages.findLast((message) => message.type === "taskToggle"));
  if (!toggle || toggle.edit.location !== markdown.indexOf("[x]") ||
      toggle.edit.expectedMarker !== "[x]" || toggle.edit.replacementMarker !== "[ ]") {
    throw new Error("Duplicate task did not target the second source marker");
  }
  const edited = markdown.slice(0, toggle.edit.location) + toggle.edit.replacementMarker +
    markdown.slice(toggle.edit.location + toggle.edit.length);
  await page.evaluate((markdown) =>
    window.gistpadPreview.render({ version: 1, documentID: "all-syntax", generation: "2", markdown }), edited);
  await page.waitForFunction(() => window.previewMessages.some((message) => message.type === "rendered" && message.generation === "2"));
  if (await checkboxes.nth(1).isChecked()) throw new Error("Native marker edit was not reflected");
  await page.getByRole("button", { name: "Ideas", exact: true }).click();
  await page.getByRole("link", { name: "the link", exact: true }).click();
  await page.getByRole("button", { name: "Reveal spoiler", exact: true }).click();
  await page.evaluate(() => window.gistpadPreview.setViewportInsets({ top: 64, bottom: 82 }));
  await page.getByRole("navigation", { name: "Contents", exact: true }).getByRole("link", { name: "Connections", exact: true }).click();
  await page.route(`${base}/Web/csp-probe.js`, (route) => route.fulfill({
    contentType: "application/javascript",
    body: 'try { new Function("return 1")(); window.previewEvalBlocked = false; } catch (error) { window.previewEvalBlocked = error instanceof EvalError; }',
  }));
  await page.addScriptTag({ url: `${base}/Web/csp-probe.js` });
  const checks = await page.evaluate(() => {
    return {
      evalBlocked: window.previewEvalBlocked === true,
      wikilink: window.previewMessages.some((message) => message.type === "link" && message.kind === "wikilink" && message.target === "Ideas"),
      external: window.previewMessages.some((message) => message.type === "link" && message.kind === "external" && message.target === "https://gistpad.dev"),
      heights: window.previewMessages.filter((message) => message.type === "height").every((message) => Number.isFinite(message.height) && message.height > 0),
      calculations: document.querySelector("article").textContent.includes("$15.00"),
      noPageOverflow: document.documentElement.scrollWidth <= window.innerWidth,
      toc: document.querySelectorAll(".markdown-toc a").length >= 6,
      outline: Array.from(document.querySelectorAll(".markdown-toc a")).every((anchor) =>
        anchor.getBoundingClientRect().height >= 44 &&
        getComputedStyle(anchor).textDecorationLine === "none" &&
        getComputedStyle(anchor).color === getComputedStyle(document.querySelector("article")).color),
      anchor: window.previewMessages.some((message) => message.type === "link" && message.kind === "anchor" && message.target === "connections"),
      insetAnchor: document.activeElement === document.getElementById("connections") &&
        Math.abs(document.getElementById("connections").getBoundingClientRect().top - 80) <= 1 &&
        getComputedStyle(document.documentElement).scrollPaddingBottom === "82px",
      alertSymbols: document.querySelectorAll(".markdown-alert-title > svg.alert-symbol[aria-hidden=true]").length === 5,
      footnotes: document.querySelectorAll("[data-footnote-ref]").length === 1,
      taskTarget: document.querySelector(".task-toggle").getBoundingClientRect().height >= 44,
      dataImage: Array.from(document.images).some((image) => image.src.startsWith("data:image/png") && image.naturalWidth === 1),
    };
  });
  for (const [name, passed] of Object.entries(checks)) {
    if (!passed) throw new Error(`Preview check failed: ${name}`);
  }
  await page.getByRole("heading", { name: "A quiet notebook", exact: true }).scrollIntoViewIfNeeded();
}
