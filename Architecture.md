# Kiến trúc AWS — Lab 16 (Phương án CPU + LightGBM)

## Sơ đồ tổng quan

```
                          INTERNET
                              |
                    +---------+---------+
                    |  Elastic IP (EIP) |
                    +-------------------+
                              |
               +--------------+--------------+
               |    Internet Gateway (IGW)   |
               |         AI-IGW              |
               +--------------+--------------+
                              |
    +=========================================================+
    |                    VPC: AI-VPC                          |
    |                   10.0.0.0/16                           |
    |                                                         |
    |   +-------------------+   +-------------------+        |
    |   | Public Subnet 0   |   | Public Subnet 1   |        |
    |   | 10.0.0.0/24       |   | 10.0.1.0/24       |        |
    |   | us-east-1a        |   | us-east-1b        |        |
    |   |                   |   |                   |        |
    |   | +--------------+  |   |                   |        |
    |   | |AI-Bastion-Host| |   |  +-------------+  |        |
    |   | | t3.micro      | |   |  |     ALB     |  |        |
    |   | | Ubuntu 22.04  | |   |  | ai-inference|  |        |
    |   | | :22 (SSH)     | |   |  | -alb        |  |        |
    |   | +------+--------+ |   |  | port 80     |  |        |
    |   |        |           |   |  +------+------+  |        |
    |   | +--------------+  |   |         |          |        |
    |   | | NAT Gateway  |  |   |         |          |        |
    |   | | AI-NAT       |  |   |         |          |        |
    |   | +--------------+  |   |         |          |        |
    |   +------|------------+   +---------|----------+        |
    |          |                          |                   |
    |          | (outbound traffic)       | (forward :8000)   |
    |          |                          |                   |
    |   +------v-----------+   +----------v---------+        |
    |   | Private Subnet 0 |   | Private Subnet 1   |        |
    |   | 10.0.10.0/24     |   | 10.0.11.0/24       |        |
    |   | us-east-1a       |   | us-east-1b         |        |
    |   |                  |   |                    |        |
    |   | +-------------+  |   |   (empty)          |        |
    |   | |AI-Inference |  |   |                    |        |
    |   | |Node         |  |   |                    |        |
    |   | |r5.2xlarge   |  |   |                    |        |
    |   | |Amazon Linux |  |   |                    |        |
    |   | |:22  :8000   |  |   |                    |        |
    |   | +-------------+  |   |                    |        |
    |   +------------------+   +--------------------+        |
    +=========================================================+
```

---

## Luồng traffic

### 1. Luồng API (Client gọi inference)

```
Client (curl/browser)
        |
        | HTTP :80
        v
  ALB (ai-inference-alb)          <- Security Group: chỉ nhận port 80 từ 0.0.0.0/0
        |
        | HTTP :8000 (forward)
        v
  AI-Inference-Node (r5.2xlarge)  <- Security Group: chỉ nhận :8000 từ ALB security group
        |
        | Flask app trả về response
        v
  ALB -> Client
```

### 2. Luồng SSH (Admin vào quản lý)

```
Admin (máy local)
        |
        | SSH :22 + agent forwarding (-A)
        v
  AI-Bastion-Host (t3.micro)      <- Security Group: nhận :22 từ 0.0.0.0/0
        |
        | SSH :22 (dùng forwarded key)
        v
  AI-Inference-Node               <- Security Group: chỉ nhận :22 từ Bastion security group
```

### 3. Luồng outbound (Instance tải packages/data)

```
AI-Inference-Node (Private Subnet)
        |
        | 0.0.0.0/0 qua Private Route Table
        v
  NAT Gateway (Public Subnet 0)   <- có Elastic IP cố định
        |
        | ra Internet qua IGW
        v
  Internet (dnf install, kaggle download, pip install...)
```

---

## Chi tiết từng thành phần

### Networking

| Thành phần | Tên | Giá trị | Vai trò |
|---|---|---|---|
| VPC | AI-VPC | `10.0.0.0/16` | Mạng riêng cô lập toàn bộ hạ tầng |
| Public Subnet 0 | Public-Subnet-0 | `10.0.0.0/24` / us-east-1a | Chứa Bastion, NAT Gateway |
| Public Subnet 1 | Public-Subnet-1 | `10.0.1.0/24` / us-east-1b | Chứa ALB node thứ 2 (HA) |
| Private Subnet 0 | Private-Subnet-0 | `10.0.10.0/24` / us-east-1a | Chứa CPU Inference Node |
| Private Subnet 1 | Private-Subnet-1 | `10.0.11.0/24` / us-east-1b | Dự phòng (hiện trống) |
| Internet Gateway | AI-IGW | — | Cổng ra Internet cho Public Subnet |
| NAT Gateway | AI-NAT | Elastic IP | Cho Private Subnet ra Internet (1 chiều) |
| Route Table (public) | public_rt | `0.0.0.0/0 → IGW` | Định tuyến Public Subnet ra Internet |
| Route Table (private) | private_rt | `0.0.0.0/0 → NAT` | Định tuyến Private Subnet qua NAT |

### Compute

| Thành phần | Tên | Spec | Vai trò |
|---|---|---|---|
| Bastion Host | AI-Bastion-Host | `t3.micro` / Ubuntu 22.04 / Public Subnet 0 | Jump server — cổng SSH an toàn vào Private Subnet |
| CPU Inference Node | AI-Inference-Node | `r5.2xlarge` (8 vCPU, 32GB RAM) / Amazon Linux 2023 / Private Subnet 0 / 50GB gp3 | Chạy LightGBM benchmark + Flask API |

### Load Balancer

| Thành phần | Tên | Chi tiết | Vai trò |
|---|---|---|---|
| Application Load Balancer | ai-inference-alb | Public, port 80, trải 2 Public Subnet | Nhận HTTP traffic từ Internet |
| Target Group | ai-inference-tg | port 8000, health check `GET /health` | Nhóm backend instance cho ALB |
| Listener | — | port 80 → forward → Target Group | Quy tắc điều hướng traffic |

### Security Groups (Firewall)

| Security Group | Inbound | Outbound | Gắn với |
|---|---|---|---|
| `ai-alb-sg` | `:80` từ `0.0.0.0/0` | All | ALB |
| `ai-bastion-sg` | `:22` từ `0.0.0.0/0` | All | Bastion Host |
| `ai-gpu-node-sg` | `:22` từ `ai-bastion-sg` / `:8000` từ `ai-alb-sg` | All | CPU Inference Node |

### IAM

| Thành phần | Tên | Vai trò |
|---|---|---|
| IAM Role | ai-inference-role-`<hex>` | Role gắn vào EC2, cho phép instance tương tác AWS services sau này |
| Instance Profile | ai-inference-profile-`<hex>` | Wrapper của IAM Role để gắn vào EC2 instance |

### SSH Key Pair

| Thành phần | File | Vai trò |
|---|---|---|
| Key Pair | `ai-lab-key-<hex>` | Dùng để SSH vào cả Bastion và CPU Node |
| Private key | `terraform/lab-key` | Lưu ở máy local (không commit lên Git) |
| Public key | `terraform/lab-key.pub` | Upload lên AWS qua Terraform |

---

## Ước tính chi phí (us-east-1, theo giờ)

| Dịch vụ | Instance | Chi phí/giờ |
|---|---|---|
| EC2 — CPU Node | `r5.2xlarge` | ~$0.504 |
| EC2 — Bastion | `t3.micro` | ~$0.010 |
| NAT Gateway | — | ~$0.045 + data transfer |
| ALB | Application LB | ~$0.008 |
| Elastic IP | (gắn với NAT) | Miễn phí khi đang dùng |
| **Tổng** | | **~$0.57/giờ** |

> **Lưu ý:** Chạy `terraform destroy` ngay sau khi nộp bài để tránh tiếp tục phát sinh chi phí.

---

## Tại sao thiết kế như vậy?

**Private Subnet cho CPU Node:** Node không có Public IP, không thể bị tấn công trực tiếp từ Internet. Chỉ có ALB (port 8000) và Bastion (port 22) mới được phép vào.

**Bastion Host:** Thay vì mở SSH trực tiếp ra Internet cho CPU Node (nguy hiểm), ta đặt một máy nhỏ (`t3.micro`) làm trạm trung chuyển. Admin SSH vào Bastion trước, rồi từ Bastion mới SSH vào Node.

**NAT Gateway:** Private Subnet không có đường ra Internet trực tiếp. NAT Gateway đứng ở Public Subnet làm cầu nối, cho phép Node kéo packages (`dnf install`, `pip install`, `kaggle download`) mà không cần Public IP.

**ALB trải 2 AZ:** ALB yêu cầu tối thiểu 2 subnet ở 2 Availability Zone khác nhau để đảm bảo tính sẵn sàng cao (High Availability), dù chỉ có 1 backend instance.

**Security Group theo tầng:** Mỗi lớp (ALB → Node, Bastion → Node) chỉ cho phép traffic đúng nguồn, đúng port — đây là mô hình **least-privilege** cho network.
