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

FROM docker.apple.com/base-images/ubi9/swift6.2-builder AS build

LABEL systemd.name="cpagent"
LABEL systemd.Unit.Description="Control Plane Agent"

WORKDIR /build

RUN curl -LO https://github.com/protocolbuffers/protobuf/releases/download/v33.1/protoc-33.1-linux-x86_64.zip && \
    unzip protoc-33.1-linux-x86_64.zip && \
    install bin/* /usr/bin && \
    mv include/* /usr/include && \
    rm -rf protoc-33.1-linux-x86_64.zip

ARG CPAGENT_VERSION=dev


# If we're running in rio we need to act as pcc-bot in order to have access to cloudattestationv2
RUN --mount=type=secret,id=PCC_BOT_GH_TOKEN,required=false \
    if [ -f /run/secrets/PCC_BOT_GH_TOKEN ]; then \
      dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo \
        && dnf install -qy git-all gh \
        && gh auth login \
             --with-token < /run/secrets/PCC_BOT_GH_TOKEN \
    else \
    fi

# Download all dependencies
COPY Package.swift Package.resolved ./
RUN --mount=type=cache,target=/build/.build \
    --mount=type=ssh,id=default,required=false \
    swift package resolve

# Then compile CPAgent binary
COPY Sources ./Sources
COPY Tests ./Tests
RUN echo "let cpagentVersion = \"${CPAGENT_VERSION}\"" > Sources/CPAgent/Configurations/Version.swift
RUN --mount=type=cache,target=/build/.build \
    swift build -c release --static-swift-stdlib --product CPAgent && \
    cp /build/.build/release/CPAgent /bin/CPAgent

# Create identity and config directories with write permissions for certificate storage
RUN mkdir -p /identity /rendered-config && chmod 777 /identity /rendered-config

FROM scratch

COPY --from=build /bin/CPAgent /bin/CPAgent
COPY --from=build /identity /identity
COPY --from=build /rendered-config /rendered-config

COPY --from=build /usr/lib64/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
COPY --from=build /usr/lib64/libc.so.6 /usr/lib64/libc.so.6
COPY --from=build /usr/lib64/libm.so.6 /usr/lib64/libm.so.6
COPY --from=build /usr/lib64/libresolv.so.2 /usr/lib64/libresolv.so.2
COPY --from=build /etc/pki/tls/certs/ca-bundle.crt /etc/pki/tls/certs/ca-bundle.crt
COPY --from=build /usr/lib64/libssl.so.3* /usr/lib64/
COPY --from=build /usr/lib64/libcrypto.so.3* /usr/lib64/
COPY --from=build /usr/lib64/libz.so.1* /usr/lib64/
COPY --from=build /usr/lib64/libstdc++.so.6* /usr/lib64/
COPY --from=build /usr/lib64/libgcc_s.so.1* /usr/lib64/
COPY --from=build /usr/lib64/libcurl.so.4* /usr/lib64/
COPY --from=build /usr/lib64/libnghttp2.so.14* /usr/lib64/
COPY --from=build /usr/lib64/libgssapi_krb5.so.2* /usr/lib64/
COPY --from=build /usr/lib64/libkrb5.so.3* /usr/lib64/
COPY --from=build /usr/lib64/libk5crypto.so.3* /usr/lib64/
COPY --from=build /usr/lib64/libcom_err.so.2* /usr/lib64/
COPY --from=build /usr/lib64/libkrb5support.so.0* /usr/lib64/
COPY --from=build /usr/lib64/libkeyutils.so.1* /usr/lib64/
COPY --from=build /usr/lib64/libselinux.so.1* /usr/lib64/
COPY --from=build /usr/lib64/libpcre2-8.so.0* /usr/lib64/

EXPOSE 8080
ENTRYPOINT ["/bin/CPAgent"]
