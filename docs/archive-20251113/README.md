de# Archived Documentation - 2025-11-13

## Why These Were Archived

These documents were created during the iterative development process. They represent historical design decisions, troubleshooting steps, and refactoring iterations. They have been superseded by the consolidated **[ARCHITECTURE.md](../../ARCHITECTURE.md)**.

## What Was Archived

1. **ROOT_CAUSE_ANALYSIS.md** - Analysis of why previous IPI and NSG approaches failed
2. **TERRAFORM_FIRST_REFACTORING.md** - Documentation of refactoring from shell-heavy to Terraform-first
3. **CLOUD_INIT_SELF_CONTAINED.md** - Evolution of cloud-init from partial to self-contained
4. **TRULY_DISCONNECTED_SOLUTION.md** - Initial bastion-serves-everything architecture
5. **NSG_DISCONNECTED_ARCHITECTURE.md** - NSG rule evolution and service tag research
6. **UPI_DEPLOYMENT_SUMMARY.md** - Early UPI implementation notes
7. **DEPLOYMENT_FIXES.md** - Collection of fixes during development

## Current Documentation

**For all architecture, deployment, and troubleshooting information, see**:  
### [ARCHITECTURE.md](../../ARCHITECTURE.md)

This single comprehensive document consolidates:
- System architecture with diagrams
- Network security design
- Bastion services (registry, git, ignition)
- Complete deployment flow
- Terraform-first principles
- Troubleshooting guide

## Historical Value

These archived documents may be useful for:
- Understanding why certain design decisions were made
- Learning from past failures and iterations
- Reference for alternative approaches that were considered
- Troubleshooting similar issues in the future

## Key Lessons Learned (Consolidated)

1. **ACR → Bastion Registry**: Simpler, truly self-contained, easier networking
2. **IPI → UPI**: Full control over networking and bootstrap process
3. **Partial → Self-Contained Cloud-Init**: Pass all vars through Terraform, zero manual config
4. **Shell-Heavy → Terraform-First**: Declarative infrastructure, minimal orchestration scripts
5. **Truly Disconnected → Azure-Functional**: Allow AzureCloud APIs for cluster operations
6. **Dynamic NSG → Subnet-Level NSG**: Avoid race conditions with CAPI

---

**These documents are historical. See [ARCHITECTURE.md](../../ARCHITECTURE.md) for current design.**

