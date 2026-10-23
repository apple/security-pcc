Copyright © 2026 Apple Inc. All Rights Reserved.

APPLE INC.
PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT
PLEASE READ THE FOLLOWING PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT (“AGREEMENT”) CAREFULLY BEFORE DOWNLOADING OR USING THE APPLE SOFTWARE ACCOMPANYING THIS AGREEMENT(AS DEFINED BELOW). BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING TO BE BOUND BY THE TERMS OF THIS AGREEMENT. IF YOU DO NOT AGREE TO THE TERMS OF THIS AGREEMENT, DO NOT DOWNLOAD OR USE THE APPLE SOFTWARE. THESE TERMS AND CONDITIONS CONSTITUTE A LEGAL AGREEMENT BETWEEN YOU AND APPLE.
IMPORTANT NOTE: BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING ON YOUR OWN BEHALF AND/OR ON BEHALF OF YOUR COMPANY OR ORGANIZATION TO THE TERMS OF THIS AGREEMENT.
1. As used in this Agreement, the term “Apple Software” collectively means and includes all of the Apple Private Cloud Compute materials provided by Apple here, including but not limited to the Apple Private Cloud Compute software, tools, data, files, frameworks, libraries, documentation, logs and other Apple-created materials. In consideration for your agreement to abide by the following terms, conditioned upon your compliance with these terms and subject to these terms, Apple grants you, for a period of ninety (90) days from the date you download the Apple Software, a limited, non-exclusive, non-sublicensable license under Apple’s copyrights in the Apple Software to download, install, compile and run the Apple Software internally within your organization only on a single Apple-branded computer you own or control, for the sole purpose of verifying the security and privacy characteristics of Apple Private Cloud Compute. This Agreement does not allow the Apple Software to exist on more than one Apple-branded computer at a time, and you may not distribute or make the Apple Software available over a network where it could be used by multiple devices at the same time. You may not, directly or indirectly, redistribute the Apple Software or any portions thereof. The Apple Software is only licensed and intended for use as expressly stated above and may not be used for other purposes or in other contexts without Apple's prior written permission. Except as expressly stated in this notice, no other rights or licenses, express or implied, are granted by Apple herein.
2. The Apple Software is provided by Apple on an "AS IS" basis. APPLE MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS, SYSTEMS, OR SERVICES. APPLE DOES NOT WARRANT THAT THE APPLE SOFTWARE WILL MEET YOUR REQUIREMENTS, THAT THE OPERATION OF THE APPLE SOFTWARE WILL BE UNINTERRUPTED OR ERROR-FREE, THAT DEFECTS IN THE APPLE SOFTWARE WILL BE CORRECTED, OR THAT THE APPLE SOFTWARE WILL BE COMPATIBLE WITH FUTURE APPLE PRODUCTS, SOFTWARE OR SERVICES. NO ORAL OR WRITTEN INFORMATION OR ADVICE GIVEN BY APPLE OR AN APPLE AUTHORIZED REPRESENTATIVE WILL CREATE A WARRANTY.
3. IN NO EVENT SHALL APPLE BE LIABLE FOR ANY DIRECT, SPECIAL, INDIRECT, INCIDENTAL OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION, COMPILATION OR OPERATION OF THE APPLE SOFTWARE, HOWEVER CAUSED AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE), STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
4. This Agreement is effective until terminated. Your rights under this Agreement will terminate automatically without notice from Apple if you fail to comply with any term(s) of this Agreement. Upon termination, you agree to cease all use of the Apple Software and destroy all copies, full or partial, of the Apple Software. This Agreement constitutes the entire understanding of the parties with respect to the subject matter contained herein, and supersedes all prior negotiations, representations, or understandings, written or oral. This Agreement will be governed and construed in accordance with the laws of the State of California, without regard to its choice of law rules.
You may report security issues about Apple products to product-security@apple.com, as described here: https://www.apple.com/support/security/. Non-security bugs and enhancement requests can be made via https://bugreport.apple.com as described here: https://developer.apple.com/bug-reporting/
EA1937
10/02/2024

# Configuration

`aea-stream-downloader` is configured via environment variables or a JSON
configuration file. All keys live under the `aea` namespace (environment
variables are prefixed with `AEA_`).

## Downloads

Each invocation can perform one or more downloads. Downloads are defined as an
indexed list under `downloads`:

```
downloads.0.sourceURL = gs://bucket/archive-a.aea
downloads.0.outputPath = /out/a
downloads.1.sourceURL = gs://bucket/archive-b.aea
downloads.1.outputPath = /out/b
```

Indices must be contiguous starting from 0. A gap (e.g. defining 0 and 2 but
not 1) stops enumeration — only downloads before the gap are processed.

Downloads are executed sequentially in index order. The process exits on the
first failure.

## Merged downloads

When multiple downloads share the same `outputPath`, their outputs are
automatically merged into a single directory. This allows combining assets from
different sources without requiring a single archive that contains everything.

```
downloads.0.sourceURL = gs://bucket/models.aea
downloads.0.outputPath = /out/combined
downloads.1.sourceURL = s3://bucket/configs/*
downloads.1.outputPath = /out/combined
downloads.1.downloadMode = plainFile
```

### How it works

Each download in a merge group writes to a hidden staging directory
(`.merge-staging/<index>/` inside the output path). After all downloads
succeed, files from each staging directory are hard-linked into the real
output directory in index order.

A `.merge-metadata` sentinel tracks which source URLs belong to the merge
group. On subsequent runs:

- If no source has changed, both downloads and the merge step are skipped.
- If any source changes, the changed source is re-downloaded to staging,
  the output directory is cleared, and all staging directories are re-merged.
- If the set of source URLs changes (download added/removed/reordered),
  all staging directories are invalidated and everything is re-downloaded.

### File conflicts

If two sources produce a file at the same relative path, the source with the
**higher index wins** (last-writer-wins). A warning is logged for each
conflict. To control precedence, order your downloads accordingly.

### Atomicity

The output directory is only modified after all downloads in the merge group
succeed. If any download fails, the output directory remains unchanged from
the previous successful merge. Staging directories preserve per-download
sentinel caching so only changed sources are re-downloaded on retry.

### Internal files

The following hidden files/directories are created inside the output path for
merge groups. They should not be modified manually:

- `.merge-staging/` — per-download staging directories with cached data
- `.merge-metadata` — merge sentinel tracking group membership

## Per-download fields

These fields can be set on each indexed download (`downloads.N.*`). When
omitted, they fall back to a global default set at the top level.

| Key | Env var (download 0) | Type | Default | Description |
|-----|----------------------|------|---------|-------------|
| `sourceURL` | `AEA_DOWNLOADS_0_SOURCE_URL` | string | *(required)* | Source to download. Supported schemes: `gs://`, `s3://`, `file://`. Append `/*` for directory mode. |
| `outputPath` | `AEA_DOWNLOADS_0_OUTPUT_PATH` | string | *(required)* | Local directory (AEA mode) or file path (plain file mode) for output. |
| `symmetricKey` | `AEA_DOWNLOADS_0_SYMMETRIC_KEY` | string | `""` | Hex-encoded symmetric key for AEA decryption. Required for `aea` mode unless Whisper is configured. May optionally include a `hex:` prefix. |
| `downloadMode` | `AEA_DOWNLOADS_0_DOWNLOAD_MODE` | string | `aea` | `aea` to decrypt an AEA archive, `plainFile` to write the object directly. |
| `chunkSizeMB` | `AEA_DOWNLOADS_0_CHUNK_SIZE_MB` | int | `1` | Size of HTTP range-request chunks in megabytes. |
| `force` | `AEA_DOWNLOADS_0_FORCE` | bool | `false` | When `true`, re-download even if the output appears up-to-date. |
| `whisper.secretName` | `AEA_DOWNLOADS_0_WHISPER_SECRET_NAME` | string | *(none)* | Whisper secret name for key retrieval. Enables Whisper-based key management. |
| `whisper.namespace` | `AEA_DOWNLOADS_0_WHISPER_NAMESPACE` | string | *(none)* | Whisper namespace for key retrieval. |
| `whisper.enabled` | `AEA_DOWNLOADS_0_WHISPER_ENABLED` | bool | *(inferred)* | Master switch for Whisper. When unset, inferred from `whisper.secretName` presence (matching the historical behaviour). Set to `false` from a higher-priority provider (typically the environment) to disable Whisper even when a lower-priority provider has fully configured it — when off, a symmetric key is required for `aea` mode. Set to `true` to assert Whisper is on; validation then rejects a missing `whisper.secretName` rather than silently falling back to symmetric-key mode. |

Global defaults for per-download fields are set at the top level (e.g.
`AEA_SYMMETRIC_KEY` applies to all downloads that don't override it).

## Global fields

These fields are set once and apply to all downloads. They cannot be overridden
per-download.

| Key | Env var | Type | Default | Description |
|-----|---------|------|---------|-------------|
| `verbose` | `AEA_VERBOSE` | bool | `false` | Enable trace-level logging. |
| `metadataBaseURL` | `AEA_METADATA_BASE_URL` | string | `http://metadata.google.internal` | GCE metadata service base URL for OAuth2 token retrieval. |
| `gcsBaseURL` | `AEA_GCS_BASE_URL` | string | `https://storage.googleapis.com` | Google Cloud Storage API base URL. |
| `fileSystemThreadPoolSize` | `AEA_FILE_SYSTEM_THREAD_POOL_SIZE` | int | `2` | Number of threads in the file-system I/O pool. |
| `writeParallelismMultiplier` | `AEA_WRITE_PARALLELISM_MULTIPLIER` | int | `4` | Multiplier for parallel write operations. |
| `tls.certificateTimeoutSeconds` | `AEA_TLS_CERTIFICATE_TIMEOUT_SECONDS` | int | `30` | Maximum seconds to wait for mTLS certificate files to appear on disk before starting downloads. |
| `http.connectTimeoutSeconds` | `AEA_HTTP_CONNECT_TIMEOUT_SECONDS` | int | `10` | TCP connect timeout in seconds for HTTP requests. |
| `http.readTimeoutSeconds` | `AEA_HTTP_READ_TIMEOUT_SECONDS` | int | `5` | Read timeout in seconds for HTTP responses. |

### Retry configuration

Controls exponential-backoff retry behavior for all HTTP requests (metadata
fetches, range downloads, token retrieval, Whisper secret fetches).

| Key | Env var | Type | Default | Description |
|-----|---------|------|---------|-------------|
| `retry.maxAttempts` | `AEA_RETRY_MAX_ATTEMPTS` | int | `20` | Maximum number of attempts per HTTP request (including the initial attempt). Must be >= 1. |
| `retry.baseDelayMilliseconds` | `AEA_RETRY_BASE_DELAY_MILLISECONDS` | int | `250` | Base delay in milliseconds before the first retry. Subsequent retries double this (exponential backoff). |
| `retry.maxDelaySeconds` | `AEA_RETRY_MAX_DELAY_SECONDS` | int | `30` | Maximum delay in seconds between retries (caps exponential backoff growth). |
| `retry.jitterFactor` | `AEA_RETRY_JITTER_FACTOR` | double | `0.25` | Random jitter added as a fraction of the computed delay (0.0 to 1.0). |

### S3 configuration

Required when any download uses an `s3://` source URL.

| Key | Env var | Type | Default | Description |
|-----|---------|------|---------|-------------|
| `s3.baseURL` | `AEA_S3_BASE_URL` | string | `""` | S3-compatible API base URL. |
| `s3.tls.certificatePath` | `AEA_S3_TLS_CERTIFICATE_PATH` | string | `""` | Path to the mTLS client certificate. |
| `s3.tls.keyPath` | `AEA_S3_TLS_KEY_PATH` | string | `""` | Path to the mTLS client private key. |
| `s3.tls.caCertificatePath` | `AEA_S3_TLS_CA_CERTIFICATE_PATH` | string | *(none)* | Path to a custom CA certificate. Optional. |

### Whisper infrastructure

Required when any download uses Whisper-based key retrieval
(`whisper.secretName` is set and `whisper.enabled` isn't overridden to
`false`).

| Key | Env var | Type | Default | Description |
|-----|---------|------|---------|-------------|
| `whisper.serverURL` | `AEA_WHISPER_SERVER_URL` | string | *(none)* | Whisper server URL. Required when any download sets `whisper.secretName`. |
| `whisper.tls.certificatePath` | `AEA_WHISPER_TLS_CERTIFICATE_PATH` | string | *(none)* | Path to the mTLS client certificate for Whisper. |
| `whisper.tls.keyPath` | `AEA_WHISPER_TLS_KEY_PATH` | string | *(none)* | Path to the mTLS client private key for Whisper. |
| `whisper.tls.caCertificatePath` | `AEA_WHISPER_TLS_CA_CERTIFICATE_PATH` | string | *(none)* | Path to a custom CA certificate for Whisper. Optional. |
| `whisper.enabled` | `AEA_WHISPER_ENABLED` | bool | *(inferred)* | Global default for the per-download `whisper.enabled` gate. |

## Environment variables

Environment variable names are derived by uppercasing, converting `camelCase`
boundaries and dots to underscores, and prefixing with `AEA_`. For indexed
downloads, the index appears after `DOWNLOADS`:

```bash
# Global defaults
AEA_SYMMETRIC_KEY=aabbccdd...          # fallback key for all downloads
AEA_VERBOSE=true
AEA_GCS_BASE_URL=https://storage.googleapis.com

# Download 0 — AEA archive
AEA_DOWNLOADS_0_SOURCE_URL=gs://bucket/archive.aea
AEA_DOWNLOADS_0_OUTPUT_PATH=/out/archive

# Download 1 — plain file, different key
AEA_DOWNLOADS_1_SOURCE_URL=gs://bucket/config.json
AEA_DOWNLOADS_1_OUTPUT_PATH=/out/config
AEA_DOWNLOADS_1_DOWNLOAD_MODE=plainFile
AEA_DOWNLOADS_1_SYMMETRIC_KEY=eeff0011...
```

## JSON configuration

The same structure maps to nested JSON objects. Indexed downloads use an object
with string keys `"0"`, `"1"`, etc.:

```json
{
  "aea": {
    "verbose": true,
    "symmetricKey": "aabbccdd...",
    "gcsBaseURL": "https://storage.googleapis.com",
    "downloads": {
      "0": {
        "sourceURL": "gs://bucket/archive.aea",
        "outputPath": "/out/archive"
      },
      "1": {
        "sourceURL": "gs://bucket/config.json",
        "outputPath": "/out/config",
        "downloadMode": "plainFile",
        "symmetricKey": "eeff0011..."
      }
    }
  }
}
```

### S3 with mTLS

```json
{
  "aea": {
    "symmetricKey": "aabbccdd...",
    "s3": {
      "baseURL": "https://conductor.data.apple.com",
      "tls": {
        "certificatePath": "/certs/chain.pem",
        "keyPath": "/certs/private.pem",
        "caCertificatePath": "/certs/ca.pem"
      }
    },
    "downloads": {
      "0": {
        "sourceURL": "s3://bucket/archive.aea",
        "outputPath": "/out/archive"
      }
    }
  }
}
```

### Whisper key retrieval

```json
{
  "aea": {
    "whisper": {
      "serverURL": "https://whisper.iss.apple.com",
      "namespace": "my-team",
      "secretName": "shared-aea-key",
      "tls": {
        "certificatePath": "/certs/chain.pem",
        "keyPath": "/certs/private.pem"
      }
    },
    "downloads": {
      "0": {
        "sourceURL": "gs://bucket/archive-a.aea",
        "outputPath": "/out/a"
      },
      "1": {
        "sourceURL": "gs://bucket/archive-b.aea",
        "outputPath": "/out/b",
        "whisper": {
          "secretName": "different-key",
          "namespace": "other-team"
        }
      }
    }
  }
}
```

## Source URL schemes

| Scheme | Example | Description |
|--------|---------|-------------|
| `gs://` | `gs://bucket/path/object.aea` | Google Cloud Storage. Uses OAuth2 from the GCE metadata service. |
| `s3://` | `s3://bucket/path/key.aea` | S3-compatible storage. Requires S3 configuration (see above). |
| `file://` | `file:///data/archive.aea` | Local file. Useful for testing. |

Append `/*` to any source URL (e.g. `gs://bucket/prefix/*`) to download all
objects matching the prefix.

## Certificate readiness

When mTLS is configured (S3 or Whisper), the downloader waits for all
referenced certificate and key files to appear on disk before starting any
downloads. This handles environments where a sidecar or init container
provisions the files asynchronously.

The wait polls every second (by default) up to `tls.certificateTimeoutSeconds`
(default 30 seconds). If the files do not appear in time, the process exits
with an error listing the missing paths.
