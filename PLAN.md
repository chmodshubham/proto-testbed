Review the entire implementation assuming it will be used on a completely fresh VM.

### Setup Validation

Check that running `env-setup.sh` (with and without flags) on a fresh VM:

* Clones/downloads everything required.
* Installs all dependencies.
* Builds all components successfully.
* Generates all required certificates and artifacts.
* Deploys everything without manual steps.

Make sure no script relies on files, directories, packages, environment variables, services, or configurations that are expected to already exist on the VM.

Verify that all paths are correct and consistently used throughout the project.

### Runtime Validation

Verify that `run.sh` works correctly for:

* TLS OpenSSL client ↔ BoringSSL NGINX server (all supported modes)
* QUIC OpenSSL client ↔ BoringSSL NGINX server (all supported modes)

Ensure startup, validation, execution, cleanup, and shutdown work correctly in every scenario.

### Manual Deployment Validation

For each protocol:

* Follow the steps in its `README.md`.
* Confirm the documented process works on a fresh VM without modifications.
* Fix any mismatch between the documentation and the actual implementation.

### Documentation

Add documentation under `docs/` for:

* Building NGINX with BoringSSL
* Required dependencies
* Build and installation steps

Follow the same format and style as the existing OpenSSL, OpenSSH, and StrongSwan documentation.

### Consistency Review

Ensure scripts, documentation, configuration files, naming, directory structure, logging, and output follow the same conventions as the existing mTLS, IPsec, and SSH implementations.

### Certificate Validation

For each protocol:

* Verify certificate generation is correct.
* Verify subject information and extensions.
* Verify trust chains.
* Verify certificates are used correctly during connections.
* Verify the correct certificates are used in every deployment mode.

### Comment Review

Review all comments and ensure they:

* Explain functionality and intent.
* Do not describe bugs, fixes, workarounds, or issue history.
* Match the current implementation.

### Robustness Review

Make scripts reliable across different VM configurations.

Check:

* Error handling
* Dependency validation
* Retry logic (where needed)
* Cleanup handling
* Idempotency
* Clear failure messages
* Low-resource and high-resource VM compatibility

Remove assumptions that could cause failures in different environments.

### Code Quality Review

Review the code for:

* Unnecessary complexity
* Duplicate logic
* Dead code
* Inefficiencies
* Readability and maintainability

Refactor where needed without changing functionality.

### Deliverables

Provide:

1. All issues found.
2. Root cause of each issue.
3. Changes made.
4. Remaining risks or assumptions.
5. Confirmation that setup, deployment, runtime, certificates, and documentation have been fully validated on a fresh VM.
