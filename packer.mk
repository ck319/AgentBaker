SHELL=/bin/bash -o pipefail

build-packer:
ifeq (${OS_SKU},Ubuntu)
ifeq (${ARCHITECTURE},ARM64)
ifeq (${MODE},gen2Mode)
	@echo "${MODE}: Building with Hyper-v generation 2 ARM64 VM"
	@packer build -var-file=vhdbuilder/packer/settings.json vhdbuilder/packer/vhd-image-builder-arm64-gen2.json
	@echo "${MODE}: Convert os disk snapshot to SIG"
	@./vhdbuilder/packer/convert-osdisk-snapshot-to-sig.sh
else ifeq (${MODE},sigMode)
	$(error sigMode not supported yet)
else
	$(error arm64 generation 1 VM not supported)
endif
else
ifeq (${MODE},gen2Mode)
	@echo "${MODE}: Building with Hyper-v generation 2 VM"
	@packer build -var-file=vhdbuilder/packer/settings.json vhdbuilder/packer/vhd-image-builder-gen2.json
else ifeq (${MODE},sigMode)
	@echo "${MODE}: Building with Hyper-v generation 1 VM and save to Shared Image Gallery"
	@packer build -var-file=vhdbuilder/packer/settings.json vhdbuilder/packer/vhd-image-builder-sig.json
else
	@echo "${MODE}: Building with Hyper-v generation 1 VM and save to Classic Storage Account"
	@packer build -var-file=vhdbuilder/packer/settings.json vhdbuilder/packer/vhd-image-builder.json
endif
endif
else ifeq (${OS_SKU},CBLMariner)
ifeq (${OS_VERSION},V1)
ifeq (${MODE},gen2Mode)
	@echo "${MODE}: Building with Hyper-v generation 2 VM and save to Classic Storage Account"
	@packer build -var-file=vhdbuilder/packer/settings.json vhdbuilder/packer/vhd-image-builder-mariner-gen2.json
else ifeq (${MODE},sigMode)
	$(error sigMode not supported yet)
else
	@echo "${MODE}: Building with Hyper-v generation 1 VM and save to Classic Storage Account"
	@packer build -var-file=vhdbuilder/packer/settings.json vhdbuilder/packer/vhd-image-builder-mariner.json
endif
else ifeq (${OS_VERSION},V2)
ifeq (${ARCHITECTURE}, ARM64)
ifeq (${MODE},gen2Mode)
	@echo "${MODE}: Building with Hyper-v generation 2 ARM64 VM"
	@packer build -var-file=vhdbuilder/packer/settings.json vhdbuilder/packer/vhd-image-builder-mariner2-arm64.json
	@echo "${MODE}: Convert os disk snapshot to SIG"
	@./vhdbuilder/packer/convert-osdisk-snapshot-to-sig.sh
else ifeq (${MODE},sigMode)
	$(error sigMode not supported yet)
else
	$(error arm64 generation 1 VM not supported)
endif
else
ifeq (${MODE},gen2Mode)
	@echo "${MODE}: Building with Hyper-v generation 2 VM"
	@packer build -var-file=vhdbuilder/packer/settings.json vhdbuilder/packer/vhd-image-builder-mariner2-gen2.json
else ifeq (${MODE},sigMode)
	$(error sigMode not supported yet)
else
	$(error MarinerV2 gen1 VMs are not supported yet)
endif
endif
else
	$(error OS_VERSION was invalid ${OS_VERSION})
endif
else
	$(error OS_SKU was invalid ${OS_SKU})
endif

build-packer-windows:
ifeq (${MODE},sigMode)
ifeq (${HYPERV_GENRATION},V1)
	@echo "${MODE}: Building with Hyper-v generation 1 VM and save to Shared Image Gallery"
else
ifeq (${GEN2_SIG_FOR_PRODUCTION},True)
	@echo "${MODE}: Building with Hyper-v generation 2 VM and save to Classic Storage Account"
else
	@echo "${MODE}: Building and save to Shared Image Gallery"
endif
endif
	@packer build -var-file=vhdbuilder/packer/settings.json vhdbuilder/packer/windows-vhd-builder-sig.json
else
	@echo "${MODE}: Building with Hyper-v generation 1 VM and save to Classic Storage Account"
	@packer build -var-file=vhdbuilder/packer/settings.json vhdbuilder/packer/windows-vhd-builder.json
endif

init-packer:
	@./vhdbuilder/packer/init-variables.sh

az-login:
	az login --service-principal -u ${CLIENT_ID} -p ${CLIENT_SECRET} --tenant ${TENANT_ID}
	az account set -s ${SUBSCRIPTION_ID}

run-packer: az-login
	@packer version && ($(MAKE) -f packer.mk init-packer | tee packer-output) && ($(MAKE) -f packer.mk build-packer | tee -a packer-output)

run-packer-windows: az-login
	@packer version && ($(MAKE) -f packer.mk init-packer | tee packer-output) && ($(MAKE) -f packer.mk build-packer-windows | tee -a packer-output)

az-copy: az-login
	azcopy-preview copy "${OS_DISK_SAS}" "${CLASSIC_BLOB}${CLASSIC_SAS_TOKEN}" --recursive=true

cleanup: az-login
	@./vhdbuilder/packer/cleanup.sh

generate-sas: az-login
	@./vhdbuilder/packer/generate-vhd-publishing-info.sh

convert-sig-to-classic-storage-account-blob: az-login
	@./vhdbuilder/packer/convert-sig-to-classic-storage-account-blob.sh

windows-vhd-publishing-info: az-login
	@./vhdbuilder/packer/generate-windows-vhd-publishing-info.sh

test-building-vhd: az-login
	@./vhdbuilder/packer/test/run-test.sh
