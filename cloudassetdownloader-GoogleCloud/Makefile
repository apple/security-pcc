.PHONY: build test clean xbuild xtest xclean format lint precommit precommit-install docker-build

IMAGE_NAME = cloudassetdownloader-mirkwood
IMAGE_TAG ?= latest
DOCKER_IMAGE = $(IMAGE_NAME):$(IMAGE_TAG)

docker-build:
	vessel build --tag $(DOCKER_IMAGE) .

SWIFTLOG_EXTRACTOR_IMAGE := docker.apple.com/mirkwood/swiftlog-extractor-swift-builder:28
SWIFTLOG_EXTRACTOR_COMMON_FLAGS := --package-product cloudassetdownloaderd --package-product cloudassetdownloader-cli

log-audit-validate:
	vessel pull $(SWIFTLOG_EXTRACTOR_IMAGE)
	vessel run -v $(shell pwd):$(shell pwd) -w $(shell pwd) -e USER=$(USER) -it $(SWIFTLOG_EXTRACTOR_IMAGE) $(SWIFTLOG_EXTRACTOR_COMMON_FLAGS) --validate-strict

log-audit-generate:
	vessel pull $(SWIFTLOG_EXTRACTOR_IMAGE)
	vessel run -v $(shell pwd):$(shell pwd) -w $(shell pwd) -e USER=$(USER) -it $(SWIFTLOG_EXTRACTOR_IMAGE) $(SWIFTLOG_EXTRACTOR_COMMON_FLAGS)

log-audit-purge:
	vessel pull $(SWIFTLOG_EXTRACTOR_IMAGE)
	vessel run -v $(shell pwd):$(shell pwd) -w $(shell pwd) -e USER=$(USER) -it $(SWIFTLOG_EXTRACTOR_IMAGE) $(SWIFTLOG_EXTRACTOR_COMMON_FLAGS) --purge

metrics-audit-validate:
	xcodebuild -scheme $(SCHEME) -destination "$(DESTINATION)" -skipPackagePluginValidation test -only-testing CloudAssetDownloaderDCoreTests

# Linux / Docker builds (swift build)
build:
	swift build

test:
	swift test

clean:
	swift package clean
	rm -rf .build

SCHEME = cloudassetdownloader-mirkwood-Package
DESTINATION = platform=macOS,name=My Mac

# Local macOS builds (xcodebuild, needed for AppleArchive headers)
xbuild:
	xcodebuild -scheme $(SCHEME) -destination "$(DESTINATION)" -skipPackagePluginValidation build

xtest:
	xcodebuild -scheme $(SCHEME) -destination "$(DESTINATION)" -skipPackagePluginValidation test

xclean:
	xcodebuild -scheme $(SCHEME) -destination "$(DESTINATION)" clean
	rm -rf ~/Library/Developer/Xcode/DerivedData

format:
	xcrun swift-format format -i --parallel --recursive Sources Tests Package.swift

lint:
	xcrun swift-format lint --strict --parallel --recursive Sources Tests Package.swift

precommit:
	xcrun swift-format format -i --parallel --recursive Sources Tests Package.swift
	xcrun swift-format lint --strict --parallel --recursive Sources Tests Package.swift
	pkl format -w --grammar-version=1 rio.pkl

precommit-install:
	pre-commit install

PROTO_SRC = Sources/CloudAssetDownloaderProto
PROTO_OUT = $(PROTO_SRC)/Generated

proto:
	protoc \
		--swift_out=Visibility=Package:$(PROTO_OUT) \
		--grpc-swift-2_out=Visibility=Package:$(PROTO_OUT) \
		--proto_path=$(PROTO_SRC) \
		$(PROTO_SRC)/cloud_asset_downloader.proto
