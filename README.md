# AWS DynamoDB 실습 — 로그인 기능이 있는 정적 웹사이트 만들기

## 1. 실습 개요

이 실습에서는 **회원가입 / 로그인 / 로그인 후 대시보드 접근** 기능을 가진 웹 서비스를
서버리스 아키텍처로 직접 구축합니다.

```
[사용자 브라우저]
      │  (정적 파일 요청: html/css/js)
      ▼
[CloudFront] ── 오리진 ──▶ [S3 버킷 (정적 웹 호스팅)]
      │
      │  (API 요청: fetch)
      ▼
[API Gateway (HTTP API)]
      │
      ▼
[Lambda 함수: signup / login / verify]
      │
      ▼
[DynamoDB 테이블: Users]
```

- **프론트엔드(정적 파일)**: S3에 업로드 → CloudFront로 배포 (문제에서 요청하신 방식)
- **백엔드**: API Gateway + Lambda (Node.js) — DynamoDB에 사용자 정보를 저장/조회
- **데이터베이스**: DynamoDB 테이블 1개 (`Users`)

## 2. 학습 목표

- DynamoDB 테이블 설계(파티션 키 선정)와 기본 CRUD API(PutItem, GetItem) 사용법 습득
- Lambda + API Gateway로 서버리스 REST API를 구성하는 방법 이해
- S3 정적 웹 호스팅 + CloudFront 배포 구조 이해 (OAC 설정 포함)
- 비밀번호 해싱, 토큰 기반 인증(JWT)의 기본 흐름 이해
- IAM 최소 권한 정책 작성 연습

## 3. 사전 준비물

- AWS 계정 (실습용 IAM 사용자, 관리자 권한 또는 아래 서비스 권한 보유)
  - DynamoDB, Lambda, API Gateway, S3, CloudFront, IAM
- Node.js 18 이상 (Lambda 배포 패키지 로컬 빌드용)
- AWS CLI v2 설치 및 `aws configure` 완료

## 4. 요구사항 (구현해야 할 기능)

1. **회원가입**: 이메일 + 비밀번호를 입력받아 DynamoDB `Users` 테이블에 저장한다.
   - 비밀번호는 평문 저장 금지 → 반드시 해싱(bcrypt) 후 저장
   - 이미 존재하는 이메일이면 가입 실패 처리 (409)
2. **로그인**: 이메일 + 비밀번호를 검증하고, 성공 시 JWT 토큰을 발급한다.
   - 비밀번호가 틀리거나 존재하지 않는 계정이면 401 반환
3. **로그인 후 대시보드**: 브라우저는 발급받은 토큰을 저장(localStorage)하고,
   `/me` API 호출 시 Authorization 헤더로 토큰을 전달하여 사용자 정보를 조회한다.
   - 토큰이 없거나 유효하지 않으면 401 반환 → 로그인 페이지로 리다이렉트
4. 위 3개 API(`/signup`, `/login`, `/me`)를 Lambda + API Gateway로 구현하고,
   프론트엔드는 S3 + CloudFront로 배포한다.

## 5. 실습 단계별 가이드

### 5.1 DynamoDB 테이블 생성

- 테이블명: `Users`
- 파티션 키: `email` (String)
- 기본 용량 모드: On-Demand(PAY_PER_REQUEST) 권장 (실습이므로 비용 절감)

`backend/dynamodb-table-create.sh` 스크립트를 참고하여 AWS CLI로 생성하세요.
(콘솔에서 직접 생성해도 무방합니다.)

### 5.2 IAM 역할/정책 구성

Lambda 실행 역할에 DynamoDB 접근 권한이 필요합니다.
`backend/iam-policy.json`은 `Users` 테이블에 대해 `PutItem`, `GetItem`, `Query`만
허용하는 최소 권한 예시입니다. Lambda 실행 역할(신뢰 정책: lambda.amazonaws.com)에
이 정책을 연결하세요. (CloudWatch Logs 쓰기 권한도 함께 필요 — 기본 관리형 정책
`AWSLambdaBasicExecutionRole`을 같이 붙이면 됩니다.)

### 5.3 Lambda 함수 작성 및 배포

`backend/lambda/` 폴더에 3개의 함수 스켈레톤이 있습니다.
**`// TODO`로 표시된 부분을 직접 채워서 완성하세요.**

- `signup.js` — 회원가입 처리
- `login.js` — 로그인 처리 및 JWT 발급
- `verify.js` — 토큰 검증 후 사용자 정보 반환 (`/me`)

배포 방법(예시, Lambda 함수당 반복):
```bash
cd backend
npm install
zip -r function.zip lambda/signup.js node_modules package.json
aws lambda create-function \
  --function-name lab-signup \
  --runtime nodejs18.x \
  --handler lambda/signup.handler \
  --role <Lambda 실행 역할 ARN> \
  --zip-file fileb://function.zip \
  --environment "Variables={TABLE_NAME=Users,JWT_SECRET=<임의의긴문자열>}"
```
login.js, verify.js도 동일한 방식으로 각각 배포합니다.
(handler 경로와 function-name만 바꿔주세요.)

> 환경변수 `JWT_SECRET`은 login.js와 verify.js에 **동일한 값**으로 설정해야 합니다.

### 5.4 API Gateway 설정

1. HTTP API 생성
2. 라우트 3개 생성 및 각 Lambda 함수와 통합
   - `POST /signup` → lab-signup
   - `POST /login` → lab-login
   - `GET /me` → lab-verify
3. **CORS 활성화** (프론트엔드 도메인 = CloudFront 도메인에서의 요청을 허용해야 함)
   - Access-Control-Allow-Origin: CloudFront 배포 도메인 (또는 실습 중엔 `*`)
   - Access-Control-Allow-Headers: `content-type,authorization`
   - Access-Control-Allow-Methods: `GET,POST,OPTIONS`
4. 배포 후 발급되는 **Invoke URL**을 기록해두세요. (예: `https://xxxx.execute-api.ap-northeast-2.amazonaws.com`)

### 5.5 프론트엔드 API 주소 연결

`frontend/js/api.js` 파일 상단의 `API_BASE_URL` 값을
5.4에서 발급받은 API Gateway Invoke URL로 수정합니다.

```js
const API_BASE_URL = "여기에_API_Gateway_URL_입력";
```

### 5.6 S3 정적 웹 호스팅

1. S3 버킷 생성 (버킷 이름은 전역에서 고유해야 함)
2. `frontend/` 폴더의 파일 전체 업로드 (index.html, signup.html, dashboard.html, css/, js/)
3. **퍼블릭 액세스는 차단 상태로 유지**하고, CloudFront에서만 접근하도록 구성 (5.7의 OAC 사용)

### 5.7 CloudFront 배포 생성

1. 오리진: 5.6에서 만든 S3 버킷 (S3 REST API 엔드포인트 사용)
2. **Origin Access Control(OAC)** 생성 및 연결 → S3 버킷 정책에 CloudFront 서비스 주체 허용 문구 자동/수동 추가
3. 기본 루트 객체: `index.html`
4. 캐시 정책: 정적 파일이므로 기본(CachingOptimized) 사용 가능
5. 배포 완료 후 발급되는 CloudFront 도메인(`*.cloudfront.net`)으로 접속 테스트

### 5.8 테스트 시나리오

1. CloudFront 도메인 접속 → 로그인 페이지 노출 확인
2. `signup.html`에서 신규 계정 생성 → DynamoDB 콘솔에서 아이템 생성 확인 (비밀번호가 해시되어 있어야 함)
3. `index.html`에서 로그인 → 성공 시 `dashboard.html`로 이동, 토큰이 localStorage에 저장되는지 확인
4. `dashboard.html`에서 `/me` 호출 결과로 이메일이 표시되는지 확인
5. 잘못된 비밀번호로 로그인 시도 → 에러 메시지 노출 확인
6. localStorage의 토큰을 삭제한 뒤 `dashboard.html` 새로고침 → 로그인 페이지로 리다이렉트되는지 확인

## 6. 제공 파일 설명

```
dynamodb-lab/
├── README.md                      # 본 문제지
├── frontend/
│   ├── index.html                 # 로그인 페이지
│   ├── signup.html                # 회원가입 페이지
│   ├── dashboard.html             # 로그인 후 진입 페이지
│   ├── css/style.css              # 공통 스타일
│   └── js/
│       ├── api.js                 # API_BASE_URL 및 공통 fetch 함수 (수정 필요)
│       ├── login.js                # 로그인 페이지 로직 (완성됨)
│       ├── signup.js               # 회원가입 페이지 로직 (완성됨)
│       └── dashboard.js            # 대시보드 로직 (완성됨)
├── backend/
│   ├── package.json               # Lambda 의존성 (bcryptjs, jsonwebtoken, aws-sdk)
│   ├── dynamodb-table-create.sh   # DynamoDB 테이블 생성 CLI 스크립트
│   ├── iam-policy.json            # Lambda용 최소 권한 IAM 정책 예시
│   └── lambda/
│       ├── signup.js              # TODO 포함 — 직접 구현
│       ├── login.js               # TODO 포함 — 직접 구현
│       └── verify.js              # TODO 포함 — 직접 구현
└── docs/
    └── API_SPEC.md                # 요청/응답 형식 명세
```

프론트엔드 코드는 **완성된 상태**로 제공되며, `api.js`의 `API_BASE_URL`만
수정하면 됩니다. 백엔드 Lambda 3개 파일은 **핵심 DynamoDB 로직 부분이 TODO로
비어있는 스켈레톤**이므로, `docs/API_SPEC.md`를 참고해 직접 채워야 합니다.

## 7. 심화 과제 (선택)

- DynamoDB에 `createdAt`, `lastLoginAt` 속성을 추가하고 GSI 없이 조건부 표현식(`ConditionExpression`)으로 중복 가입 방지 처리 강화
- 로그인 실패 횟수를 DynamoDB에 기록하여 5회 실패 시 일정 시간 잠금 처리
- JWT 대신 DynamoDB에 세션 아이템을 저장하고 TTL(Time To Live) 속성으로 자동 만료 구현
- CloudFront에 커스텀 도메인 + ACM 인증서 연결 (HTTPS)
- API Gateway에 사용량 제한(Usage Plan/Throttling) 적용

## 8. 참고 자료

- DynamoDB 개발자 가이드: https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/
- Lambda + API Gateway 튜토리얼: https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-develop-integrations-lambda.html
- CloudFront + S3 OAC 설정 가이드: https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-s3.html
