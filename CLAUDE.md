# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

This repository is a scaffold with no source code yet. It contains only a README and an IntelliJ
project configuration (Java module, JDK `zulu-26`, Checkstyle with bundled Sun/Google checks
enabled). There is no build file (Maven/Gradle), no source directory, and no tests.

## Intent

Per the README, `agent-cli` is meant to become an orchestrator CLI for isolated AI agent
development: managing Git worktrees, DevContainers/Sandboxes, and pull requests for clean task
execution.

## Working in this repo right now

- The project is configured for Java (JDK 26 via Zulu) in IntelliJ, so new code should be Java
  unless the user says otherwise.
- Checkstyle (Sun Checks + Google Checks) is enabled in the IDE — follow those conventions when
  writing Java code.
- Since there is no build tooling yet, if the user asks to start implementing, check with them on
  which build system (Maven/Gradle) and project layout they want before scaffolding one.