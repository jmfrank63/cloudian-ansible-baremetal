# define PROJECT_DIR
# define INFRA

all: $(PROJECT_DIR)/inventory.yaml $(PROJECT_DIR)/main.tf cc.png

$(PROJECT_DIR)/cluster.yaml $(PROJECT_DIR)/virt.yaml: $(PROJECT_DIR)/main.yaml split.py
	./split.py $(PROJECT_DIR)/main.yaml $(PROJECT_DIR)/cluster.yaml $(PROJECT_DIR)/virt.yaml

$(PROJECT_DIR)/main.tf: $(PROJECT_DIR)/virt.yaml infra/$(INFRA).yaml virt2tf.py
	./virt2tf.py $(PROJECT_DIR)/virt.yaml infra/$(INFRA).yaml $(PROJECT_DIR)/main.tf

$(PROJECT_DIR)/inventory.yaml: $(PROJECT_DIR)/cluster.yaml cluster_config2cab.py
	./cluster_config2cab.py $(PROJECT_DIR)/cluster.yaml $(PROJECT_DIR)/inventory.yaml

cc.png: cc.dot
	dot -Tpng $< > $@
