# Nexus SDV: Getting Started Guide

Welcome to the Nexus SDV ecosystem. This guide is designed to take you from a fresh repository to a fully functional connected vehicle cloud backend in just a few logical steps. Whether you are an architect evaluating the framework or a developer building custom services, the following sections provide the technical foundation and hands-on instructions needed to succeed.

## The Path to Your Own Platform

Follow these four steps to deploy, connect, and extend your Nexus instance:

* **[1. Deployment](deployment.mdx)** Learn how to provision your own Nexus instance on **Google Cloud** using Terraform and GitHub Actions. This guide covers the entire infrastructure setup.

* **[2. Connected Clients](clients.md)** Once your platform is live, use our client examples to establish a secure **mTLS connection**. This section explains how to start communicating with the backend.

* **[3. Custom Services](services.md)** Learn how to leverage Nexus as a foundation for differentiated automotive services based on our example.

* **[4. Resource Teardown](teardown.mdx)** Essential for Proof of Concepts (PoC). This guide explains how to efficiently decommission your environment.

---

## Preview: Interactive Online Documentation

While this GitHub-based documentation provides the core technical steps, we are currently finalizing a comprehensive, interactive documentation portal at **docs.nexus-sdv.io**.

The upcoming portal will offer a significantly enhanced user experience, including global search, and a streamlined navigation flow.

| Home Page Sneak Peek | Deployment Guide Preview |
| :--- | :--- |
| ![Online Documentation Home](assets/Nexus-Online-Docs-Home.png) | ![Online Documentation Deployment](assets/Nexus-Online-Docs-Deploy.png) |

> **Note on Content Rendering:** > The upcoming online documentation is developed with **Astro**. Consequently, you may notice specific formatting tags (such as `:::tip` or `:::note`). While these appear as plain text here on GitHub, they will be rendered as color-coded callout boxes in the final online version.