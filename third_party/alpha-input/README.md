### AI增强输入的插件（待接入输入法）
模型下载方法：
1. 安装依赖`pip install torch transformers optimum[onnxruntime] numpy lmdb tqdm`
2. 修改`script/download.py`第18行的模型id(huggingface)，建议默认或者改为 `Qwen/Qwen3-0.6B`，在上一级目录找到模型文件夹
3. 分别在`export_embeddings_lmdb.py`和`export_onnx.py`底部查看参数，把它修改为正确的模型路径（或直接在命令行中指定），运行分别导出的是词嵌入数据库和模型相关文件
4. 修改`config.toml`为正确的模型路径