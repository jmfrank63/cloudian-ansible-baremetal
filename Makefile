# define PROJECT_DIR
# define INFRA

project=$(shell basename $(PROJECT_DIR))

MAIN=$(PROJECT_DIR)/main.yaml
CLUSTER=$(PROJECT_DIR)/cluster.yaml
SURVEY=$(PROJECT_DIR)/survey.csv
PRESEED=$(PROJECT_DIR)/preseed.conf
VIRT=$(PROJECT_DIR)/virt.yaml
INVENTORY=$(PROJECT_DIR)/inventory.yaml
FIXED=$(PROJECT_DIR)/inventory-fixed.yaml

TF_FILE=$(PROJECT_DIR)/main.tf
TF_STATE=$(PROJECT_DIR)/terraform.tfstate

PRV_KEY=$(PROJECT_DIR)/cloudian-installation-key
PUB_KEY=$(PROJECT_DIR)/cloudian-installation-key.pub


all: $(INVENTORY) $(TF_FILE) \
	$(PRV_KEY) $(PUB_KEY) \
	cc.png

$(CLUSTER) $(VIRT): $(MAIN) split.py
	./split.py $(MAIN) $(CLUSTER) $(VIRT)

$(TF_FILE): $(VIRT) infra/$(INFRA).yaml $(PUB_KEY) virt2tf.py
	./virt2tf.py $(VIRT) infra/$(INFRA).yaml $(TF_FILE)

$(SURVEY) $(PRESEED) $(INVENTORY): $(CLUSTER) cluster_config2cab.py
	./cluster_config2cab.py $(CLUSTER) $(SURVEY) $(PRESEED) $(INVENTORY)

$(FIXED): $(INVENTORY) $(TF_STATE) tf2cluster.py
	./tf2cluster.py $(INVENTORY) $(TF_STATE) $(FIXED)

$(PRV_KEY) $(PUB_KEY):
	# TODO: PROJECT_DIR is 'projects/demo3/', make it 'demo3'
	ssh-keygen -v -b 2048 -t rsa -f $(PRV_KEY) -q -N '' -C "cloudian-installation-key@$(project)"

cc.png: cc.dot
	dot -Tpng $< > $@

clean:
	rm --force $(CLUSTER) $(VIRT) $(INVENTORY) $(FIXED)

really-clean: clean
	rm --force $(TF_FILE) $(TF_STATE) $(PRV_KEY) $(PUB_KEY)
