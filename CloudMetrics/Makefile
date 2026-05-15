REPO_ROOT ?= $(shell git rev-parse --show-toplevel)

ABI_DERIVED_DATA := ${REPO_ROOT}/.ABI_DerivedData
ABI_BASELINES_DIR := ${REPO_ROOT}/ABI_Baselines
ABI_COLLECTION_SCRIPT := ${REPO_ROOT}/SupportingFiles/Scripts/ABICollection.sh

TRAIN := LuckCLining

# roots ------------------------------------------------------------------------
.PHONY: lint
lint:
	@echo "linting..."
	@swiftlint lint --quiet --strict --config .swiftlint.yml Sources

.PHONY: abi
abi:
	@echo "Building abi schema..."
	@xcodebuild \
		-project CloudMetrics.xcodeproj \
		-scheme abi \
		-destination generic/platform=iOS \
		-destination generic/platform=macOS \
		-derivedDataPath ${ABI_DERIVED_DATA} \
		RUN_SWIFT_ABI_CHECKER_TOOL=NO
	@${ABI_COLLECTION_SCRIPT} ${ABI_DERIVED_DATA} ${ABI_BASELINES_DIR}

.PHONY: protos
protos:
	protoc Tests/FakeOTLPServer/Protos/*.proto --grpc-swift_out=. --swift_out=. --grpc-swift_opt=Client=false

# Generic VRE

.PHONY:
cryptex:
	sudo cloudos-build-helper  --project . -t ${TRAIN} --skip-sdk-install --incremental --setup-vre -c PrivateCloudSupport -u

.PHONY:
vre: cryptex
	pccvre instance start --quiet --name ${VRE}

.PHONY:
vre-wait-rem:
	( while ! pccvre instance diagnostic --name ${VRE} get-cloud-board-health | grep -iq "healthy" ; do sleep 1; done ) &> /dev/null

.PHONY:
vre-ssh: vre-wait-rem
	$(SSH)

.PHONY:
vre-ssh-no-wait:
	$(SSH)

.PHONY:
adc: cryptex
	devicecompute session create --manifest-train ${TRAIN} --role cloudmetrics --darwin-init-cryptex '@/tmp/cloudos_buildhelper/upload-urls.json'

.PHONY:
vre-copy-crash:
	@CRASH_FILE=$$($(SSH) "ls -t /private/var/mobile/Library/Logs/CrashReporter/*.ips 2>/dev/null | head -n1"); \
	if [ -n "$$CRASH_FILE" ]; then \
		echo "Copying most recent crash file: $$CRASH_FILE"; \
		$(SSH) "cat $$CRASH_FILE" | pbcopy && \
		echo "Crash file copied to clipboard"; \
	else \
		echo "No .ips crash files found"; \
	fi
