#!/bin/bash
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

echo "Starting LightGBM CPU benchmark setup on r5.2xlarge"

# Update system and install Python + ML packages
sudo dnf update -y
sudo dnf install -y python3 python3-pip git
pip3 install --upgrade pip
pip3 install lightgbm scikit-learn pandas numpy flask kaggle

# Create working directory
mkdir -p /home/ec2-user/ml-benchmark
chown ec2-user:ec2-user /home/ec2-user/ml-benchmark

# Create benchmark script
cat > /home/ec2-user/ml-benchmark/benchmark.py << 'PYEOF'
import time, json
import pandas as pd
import numpy as np
import lightgbm as lgb
from sklearn.model_selection import train_test_split
from sklearn.metrics import roc_auc_score, accuracy_score, f1_score, precision_score, recall_score

print("=== LightGBM Benchmark on r5.2xlarge ===")
results = {}

# Load data
t0 = time.time()
df = pd.read_csv("creditcard.csv")
results["load_time_sec"] = round(time.time() - t0, 3)
print(f"Load time: {results['load_time_sec']}s | Shape: {df.shape}")

X = df.drop("Class", axis=1)
y = df["Class"]
X_train, X_test, y_train, y_test = train_test_split(
    X, y, test_size=0.2, random_state=42, stratify=y
)

dtrain = lgb.Dataset(X_train, label=y_train)
dval   = lgb.Dataset(X_test,  label=y_test, reference=dtrain)

params = {
    "objective":     "binary",
    "metric":        "auc",
    "n_jobs":        -1,
    "verbosity":     -1,
    "num_leaves":    63,
    "learning_rate": 0.05,
}

# Train
t0 = time.time()
model = lgb.train(
    params, dtrain, num_boost_round=300,
    valid_sets=[dval],
    callbacks=[lgb.early_stopping(30), lgb.log_evaluation(50)],
)
results["train_time_sec"]  = round(time.time() - t0, 3)
results["best_iteration"]  = model.best_iteration
print(f"Train time: {results['train_time_sec']}s | Best iter: {model.best_iteration}")

# Evaluate
y_pred_proba = model.predict(X_test)
y_pred       = (y_pred_proba > 0.5).astype(int)
results["auc_roc"]   = round(roc_auc_score(y_test, y_pred_proba), 6)
results["accuracy"]  = round(accuracy_score(y_test, y_pred),       6)
results["f1_score"]  = round(f1_score(y_test, y_pred),             6)
results["precision"] = round(precision_score(y_test, y_pred),      6)
results["recall"]    = round(recall_score(y_test, y_pred),         6)

# Inference latency
single = X_test.iloc[[0]]
t0 = time.time()
for _ in range(100):
    model.predict(single)
results["inference_latency_1row_ms"]         = round((time.time() - t0) / 100 * 1000, 3)

batch = X_test.iloc[:1000]
t0 = time.time()
model.predict(batch)
results["inference_throughput_1000rows_ms"] = round((time.time() - t0) * 1000, 3)

print("\n=== RESULTS ===")
for k, v in results.items():
    print(f"  {k}: {v}")

with open("benchmark_result.json", "w") as f:
    json.dump(results, f, indent=2)
print("\nbenchmark_result.json saved.")
PYEOF

chown ec2-user:ec2-user /home/ec2-user/ml-benchmark/benchmark.py

# Flask health + result server on port 8000 (for ALB health check)
cat > /opt/health_server.py << 'PYEOF'
from flask import Flask, jsonify
import json, os

app = Flask(__name__)

@app.route("/health")
def health():
    return jsonify({"status": "ok"}), 200

@app.route("/v1/benchmark")
def benchmark_result():
    result_file = "/home/ec2-user/ml-benchmark/benchmark_result.json"
    if os.path.exists(result_file):
        with open(result_file) as f:
            return jsonify(json.load(f)), 200
    return jsonify({"status": "benchmark not run yet"}), 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)
PYEOF

# Start Flask server in background so ALB health check passes
nohup python3 /opt/health_server.py > /var/log/health_server.log 2>&1 &

echo "Setup complete. SSH in and run: cd ~/ml-benchmark && python3 benchmark.py"
