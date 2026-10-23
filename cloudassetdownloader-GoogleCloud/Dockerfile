# Copyright © 2026 Apple Inc. All Rights Reserved.

# APPLE INC.
# PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT
# PLEASE READ THE FOLLOWING PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT (“AGREEMENT”) CAREFULLY BEFORE DOWNLOADING OR USING THE APPLE SOFTWARE ACCOMPANYING THIS AGREEMENT(AS DEFINED BELOW). BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING TO BE BOUND BY THE TERMS OF THIS AGREEMENT. IF YOU DO NOT AGREE TO THE TERMS OF THIS AGREEMENT, DO NOT DOWNLOAD OR USE THE APPLE SOFTWARE. THESE TERMS AND CONDITIONS CONSTITUTE A LEGAL AGREEMENT BETWEEN YOU AND APPLE.
# IMPORTANT NOTE: BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING ON YOUR OWN BEHALF AND/OR ON BEHALF OF YOUR COMPANY OR ORGANIZATION TO THE TERMS OF THIS AGREEMENT.
# 1. As used in this Agreement, the term “Apple Software” collectively means and includes all of the Apple Private Cloud Compute materials provided by Apple here, including but not limited to the Apple Private Cloud Compute software, tools, data, files, frameworks, libraries, documentation, logs and other Apple-created materials. In consideration for your agreement to abide by the following terms, conditioned upon your compliance with these terms and subject to these terms, Apple grants you, for a period of ninety (90) days from the date you download the Apple Software, a limited, non-exclusive, non-sublicensable license under Apple’s copyrights in the Apple Software to download, install, compile and run the Apple Software internally within your organization only on a single Apple-branded computer you own or control, for the sole purpose of verifying the security and privacy characteristics of Apple Private Cloud Compute. This Agreement does not allow the Apple Software to exist on more than one Apple-branded computer at a time, and you may not distribute or make the Apple Software available over a network where it could be used by multiple devices at the same time. You may not, directly or indirectly, redistribute the Apple Software or any portions thereof. The Apple Software is only licensed and intended for use as expressly stated above and may not be used for other purposes or in other contexts without Apple's prior written permission. Except as expressly stated in this notice, no other rights or licenses, express or implied, are granted by Apple herein.
# 2. The Apple Software is provided by Apple on an "AS IS" basis. APPLE MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS, SYSTEMS, OR SERVICES. APPLE DOES NOT WARRANT THAT THE APPLE SOFTWARE WILL MEET YOUR REQUIREMENTS, THAT THE OPERATION OF THE APPLE SOFTWARE WILL BE UNINTERRUPTED OR ERROR-FREE, THAT DEFECTS IN THE APPLE SOFTWARE WILL BE CORRECTED, OR THAT THE APPLE SOFTWARE WILL BE COMPATIBLE WITH FUTURE APPLE PRODUCTS, SOFTWARE OR SERVICES. NO ORAL OR WRITTEN INFORMATION OR ADVICE GIVEN BY APPLE OR AN APPLE AUTHORIZED REPRESENTATIVE WILL CREATE A WARRANTY.
# 3. IN NO EVENT SHALL APPLE BE LIABLE FOR ANY DIRECT, SPECIAL, INDIRECT, INCIDENTAL OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION, COMPILATION OR OPERATION OF THE APPLE SOFTWARE, HOWEVER CAUSED AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE), STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
# 4. This Agreement is effective until terminated. Your rights under this Agreement will terminate automatically without notice from Apple if you fail to comply with any term(s) of this Agreement. Upon termination, you agree to cease all use of the Apple Software and destroy all copies, full or partial, of the Apple Software. This Agreement constitutes the entire understanding of the parties with respect to the subject matter contained herein, and supersedes all prior negotiations, representations, or understandings, written or oral. This Agreement will be governed and construed in accordance with the laws of the State of California, without regard to its choice of law rules.
# You may report security issues about Apple products to product-security@apple.com, as described here: https://www.apple.com/support/security/. Non-security bugs and enhancement requests can be made via https://bugreport.apple.com as described here: https://developer.apple.com/bug-reporting/
# EA1937
# 10/02/2024

ARG swiftVersion=6.2

# AppleArchive ships static archives (.a) in the `mw` variant, so AppleArchive
# can be linked statically into the binaries and we don't have to ship its .so
# at runtime. See rdar://179892028.
FROM docker.apple.com/coreosvn/apple-archive-ubi9mw:1 AS aea
FROM docker.apple.com/base-images/ubi9/swift$swiftVersion-builder AS builder

RUN yum install -y libacl-devel bzip2-devel openssl-devel

# Only copy static archives (.a) and headers. The archives ship with a `_static`
# suffix; rename them so the modulemap's `link "AppleArchive"` /
# `link "compression"` resolves correctly.
COPY --from=aea /AppleArchiveRoots/usr/lib/*.a /usr/lib64/
COPY --from=aea /AppleArchiveRoots/usr/lib/*.a /usr/lib/
COPY --from=aea /AppleArchiveRoots/usr/include/ /usr/include/
RUN mv /usr/lib64/libAppleArchive_static.a /usr/lib64/libAppleArchive.a \
    && mv /usr/lib64/libcompression_static.a /usr/lib64/libcompression.a \
    && mv /usr/lib/libAppleArchive_static.a /usr/lib/libAppleArchive.a \
    && mv /usr/lib/libcompression_static.a /usr/lib/libcompression.a

WORKDIR /build

# In CI, set up GitHub token auth. Locally, SSH-agent forwarding is used instead.
RUN --mount=type=secret,id=pcc-bot-gh-token,required=false \
    if [ -f /run/secrets/pcc-bot-gh-token ]; then \
      dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo \
        && dnf install -qy git-all gh \
        && gh auth login \
             --with-token < /run/secrets/pcc-bot-gh-token \
        && git config --global \
    fi

COPY . .


# Locally, rewrite HTTPS package URLs to SSH so the SSH agent mount is used.
RUN --mount=type=secret,id=pcc-bot-gh-token,required=false \
    if [ ! -f /run/secrets/pcc-bot-gh-token ]; then \
      git config --global \
    fi

# `--static-swift-stdlib` links the Swift stdlib + concurrency runtime +
# libdispatch into each binary, so the runtime image doesn't need to ship the
# Swift .so's. `strip --strip-debug` drops DWARF but keeps `.symtab`, so
# swift-backtrace can still produce demangled crash traces in `fast` mode.
RUN --mount=type=ssh,id=default,required=false \
    --mount=type=cache,id=swiftpm-cache,target=/root/.cache \
    --mount=type=cache,id=swift-build,target=/build/.build,sharing=locked \
    swift build -c release --static-swift-stdlib \
    && mkdir -p /out \
    && cp .build/release/cloudassetdownloaderd /out/ \
    && cp .build/release/cloudassetdownloader-cli /out/ \
    && strip --strip-debug /out/cloudassetdownloaderd \
    && strip --strip-debug /out/cloudassetdownloader-cli

FROM docker.apple.com/base-images/ubi9-micro/ubi-micro-runtime

# AppleArchive's static archive references symbols from libbz2, liblzma, and
# libcrypto; the resulting binaries keep NEEDED entries on those .sos. libcrypto
# in turn needs libz. The Swift static stdlib pulls in libxml2 (Foundation),
# libstdc++ (libdispatch) and libgcc_s. ubi-micro-runtime doesn't ship any of
# them, so copy them from the build image.
COPY --from=builder /usr/lib64/libbz2.so.1* /usr/lib64/
COPY --from=builder /usr/lib64/liblzma.so.5* /usr/lib64/
COPY --from=builder /usr/lib64/libcrypto.so.3* /usr/lib64/
COPY --from=builder /usr/lib64/libz.so.1* /usr/lib64/
COPY --from=builder /usr/lib64/libxml2.so.2* /usr/lib64/
COPY --from=builder /usr/lib64/libstdc++.so.6* /usr/lib64/
COPY --from=builder /usr/lib64/libgcc_s.so.1* /usr/lib64/

COPY --from=builder /out/cloudassetdownloaderd /bin/cloudassetdownloaderd
COPY --from=builder /out/cloudassetdownloader-cli /bin/cloudassetdownloader-cli

# Static swift-backtrace helper for symbolicated crash reports. The dynamic
# variant needs the swift stdlib .so's, which we don't ship; the static one
# only depends on libs already present in this image.
COPY --from=builder /usr/libexec/swift/linux/swift-backtrace-static /usr/libexec/swift/linux/swift-backtrace-static
ENV SWIFT_BACKTRACE=enable=on,symbolicate=fast,swift-backtrace=/usr/libexec/swift/linux/swift-backtrace-static

USER root
RUN mkdir -p /cloud-assets && chown 1014:1014 /cloud-assets
USER 1014

ENTRYPOINT ["/bin/cloudassetdownloaderd"]
