async (page) => {
  const base = "http://127.0.0.1:4181";
  await page.addInitScript(() => {
    window.__painted = [];
    let generation = 0;
    window.webkit = { messageHandlers: { gistpadDocumint: { postMessage(event) {
      if (event.type === "changed") {
        queueMicrotask(() => window.gistpadDocumint.acknowledge(event.revision, String(++generation)));
      }
    } } } };
    const fillText = CanvasRenderingContext2D.prototype.fillText;
    CanvasRenderingContext2D.prototype.fillText = function(text, x, y, ...rest) {
      window.__painted.push({ text, x, y, color: this.fillStyle, font: this.font });
      return fillText.call(this, text, x, y, ...rest);
    };
  });
  const markdown = await (await page.request.get(`${base}/parity.md`)).text();
  await page.goto(`${base}/Web/index.html`);
  await page.waitForFunction(() => Boolean(window.gistpadDocumint));
  await page.setViewportSize({ width: 466, height: 678 });
  await page.evaluate((markdown) => window.gistpadDocumint.setDocument({
    documentID: "parity", generation: "0", markdown,
  }), markdown);
  await page.waitForFunction(() => window.gistpadDocumint.metrics().openToPaintMS !== null);
  const evidence = "/Users/lostintangent/.toy-box/sessions/b1a23830-77ef-4284-8f6f-a90c304af54a/artifacts/documint-spike";
  const appearances = [];
  for (const dark of [false, true]) {
    for (const bodySize of [17, 40, 53]) {
      const theme = {
        dark, bodySize, text: dark ? "#ffffff" : "#000000",
        muted: dark ? "#aaaaaa" : "#666666", background: dark ? "#000000" : "#ffffff",
        surface: dark ? "#1c1c1e" : "#f2f2f7", border: dark ? "#545458" : "#c6c6c8",
        blue: dark ? "#0a84ff" : "#007aff", accentText: dark ? "#a7d3c3" : "#235e4b",
        accentFill: "#427566", onAccent: "#ffffff",
      };
      await page.evaluate((theme) => {
        window.__painted = [];
        document.querySelector(".documint-scroll-container").scrollTop = 0;
        window.gistpadDocumint.setAppearance(theme);
      }, theme);
      await page.waitForTimeout(250);
      const draws = await page.evaluate(() => window.__painted);
      appearances.push({
        dark, bodySize,
        headingFonts: [...new Set(draws.filter(item => item.text.includes("rich")).map(item => item.font))],
        textUsesSystemFont: draws.every(item => item.font.includes("-apple-system") ||
          item.font.includes("ui-monospace") || item.font.includes("sans-serif")),
        metrics: await page.evaluate(() => window.gistpadDocumint.metrics()),
      });
      await page.screenshot({ path: `${evidence}/browser-${dark ? "dark" : "light"}-${bodySize}.png` });
    }
  }
  await page.evaluate(() => {
    window.__painted = [];
    window.gistpadDocumint.setAppearance({
      dark: false, bodySize: 17, text: "#000000", muted: "#666666", background: "#ffffff",
      surface: "#f2f2f7", border: "#c6c6c8", blue: "#007aff",
      accentText: "#235e4b", accentFill: "#427566", onAccent: "#ffffff",
    });
  });
  await page.waitForTimeout(200);
  const initialDraws = await page.evaluate(() => window.__painted);
  const task = initialDraws.find(item => item.text.includes("Clean the kitchen"));
  if (!task) throw new Error("The authored task was not painted");
  await page.mouse.click(task.x - 17, task.y - 5);
  await page.waitForFunction(() => window.gistpadDocumint.snapshot().markdown.includes("[x] Clean the kitchen"));
  const aria = await page.locator("body").ariaSnapshot();
  await page.evaluate(() => {
    document.querySelector(".documint-scroll-container").scrollTop = 650;
  });
  await page.waitForTimeout(250);
  await page.screenshot({ path: `${evidence}/browser-parity-bottom.png` });
  const bottomDraws = await page.evaluate(() => window.__painted.map(item => item.text));
  return {
    appearances, taskClickReachesSource: true, accessibilityTree: aria,
    mermaidIsSourceNotDiagram: bottomDraws.some(text => text.includes("flowchart")),
  };
}
