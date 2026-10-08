"""LLM-as-a-Judge evaluation of the local-model comparison (TEST dataset only).

Independent of the generation harness and of the app: nothing in backend/ imports this package.
Translation generation stays on local Ollama; only the dataset test items and their candidate
translations are evaluated, by the `translation-judge` Claude Code subagent (model: opus).
"""
