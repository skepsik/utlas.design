import { defineConfig } from "vitepress";

export default defineConfig({
  title: "Utlas design",
  description: "Канонический design для Utlas (TS runtime)",
  lang: "ru-RU",
  base: "/utlas/wiki/",
  srcDir: "content",
  cleanUrls: true,
  themeConfig: {
    nav: [{ text: "Home", link: "/" }],
    sidebar: [
      {
        text: "Core",
        items: [
          { text: "Layout", link: "/layout" },
          { text: "Domain", link: "/domain" },
          { text: "Semantic thread", link: "/semantic-thread" },
          { text: "Storage mapping", link: "/storage-mapping" },
        ],
      },
      {
        text: "Turn & transport",
        items: [
          { text: "Turn pipeline", link: "/turn-pipeline" },
          { text: "Transport", link: "/transport" },
          { text: "Turn prompt", link: "/turn-prompt" },
          { text: "LLM execution policy", link: "/llm-execution-policy" },
        ],
      },
      {
        text: "LLM answer envelope",
        items: [
          { text: "Overview", link: "/envelope/" },
          { text: "Journal", link: "/envelope/journal" },
          { text: "Compose blocks", link: "/envelope/compose-blocks" },
        ],
      },
      {
        text: "Tools",
        items: [
          { text: "Overview", link: "/tools/" },
          { text: "Geocode", link: "/tools/geocode" },
          { text: "Message search", link: "/tools/message-search" },
        ],
      },
      {
        text: "Structure (later)",
        items: [{ text: "Tenancy", link: "/tenancy" }],
      },
      {
        text: "Attention",
        items: [
          { text: "Overview", link: "/attention/" },
          { text: "Registries", link: "/attention/registries" },
        ],
      },
      {
        text: "Prompts",
        items: [{ text: "Context bus", link: "/prompts/context-bus" }],
      },
    ],
    socialLinks: [
      {
        icon: "github",
        link: "https://github.com/skepsik/utlas.design",
      },
    ],
    search: {
      provider: "local",
    },
  },
});
