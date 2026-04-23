# Báo cáo Lab 16 — Phương án CPU thay thế (LightGBM trên `r5.2xlarge`)

**Lý do dùng CPU thay GPU:** Tài khoản AWS mới bị giới hạn quota GPU mặc định ở mức 0 vCPU cho dòng instance G/VT (`g4dn.xlarge`). Yêu cầu tăng quota thường bị trì hoãn hoặc từ chối với tài khoản Free Tier, nên phương án thay thế là dùng instance CPU cao cấp `r5.2xlarge` (8 vCPU, 32 GB RAM) không cần quota đặc biệt.

**Kết quả training:** Model LightGBM hội tụ rất nhanh (best iteration = 1, train time = 0.791s) nhờ early stopping phát hiện không còn cải thiện trên tập validation. Thời gian load dataset 284.807 dòng từ CSV mất 1.774 giây.

**Kết quả đánh giá:** AUC-ROC đạt **0.9415**, Accuracy **99.9%**, Recall **83.7%** — cho thấy model phát hiện gian lận tốt dù dataset cực kỳ mất cân bằng (chỉ ~0.17% giao dịch là gian lận). F1-Score đạt 0.742, Precision 0.667.

**Kết quả inference:** Độ trễ với 1 dòng dữ liệu là **0.344ms**, throughput với 1000 dòng là **0.522ms** — cho thấy LightGBM phù hợp với hệ thống cần real-time fraud detection với độ trễ cực thấp.

**So sánh với GPU:** Phương án GPU (vLLM + Gemma) tối ưu cho bài toán sinh ngôn ngữ tự nhiên, trong khi LightGBM trên CPU hoàn toàn đáp ứng bài toán classification có cấu trúc (tabular data) với chi phí tương đương (~$0.504/giờ cho `r5.2xlarge` so với ~$0.526/giờ cho `g4dn.xlarge`) nhưng không cần xin quota đặc biệt.
