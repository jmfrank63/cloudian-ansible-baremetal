all: cluster.yaml main.tf cc.png

hs.yaml virt.yaml: examples/demo3.yaml split.py
	./split.py examples/demo3.yaml

main.tf: virt.yaml infras/ams.yaml virt2tf.py
	./virt2tf.py virt.yaml infras/ams.yaml

cluster.yaml: hs.yaml cluster_config2cab.py
	./cluster_config2cab.py hs.yaml cluster.yaml

cc.png: cc.dot
	dot -Tpng $< > $@
