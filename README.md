# we

가족이 서로의 건강 기록과 안부를 가볍게 공유하는 캐릭터 중심 가족 소셜 앱 프로토타입입니다.

## Demo

https://check-family-health.com

## 현재 포함된 흐름

- Google·Naver·Kakao 로그인 화면
- 한 명으로 시작하는 가족방과 초대 코드
- 가족 구성원의 프로필·애칭·캐릭터 설정
- Apple 건강·Samsung Health·Health Connect 연결 미리보기
- 가족별 건강 카드와 날짜 기반 기록
- AI 건강 대화 요약 기록
- 설치 가능한 PWA 구성
- Supabase 가족 그룹 데이터 모델과 가족방별 접근 제어(RLS)
- 가족방 생성 한도·방별 인원 한도와 평생 확장 권한 모델
- 구성원·가족방 상태 변경 및 AI/전문가 상담 이력 보존

## Supabase

Supabase 프로젝트 연결 정보는 `dist/config.js`에 있고, 데이터베이스 구성은
`supabase/migrations/202609200001_family_core.sql`에 있습니다. 공개용 publishable key만
클라이언트에서 사용하며, 관리자 키와 데이터베이스 비밀번호는 저장소에 넣지 않습니다.

## 로컬 실행

별도의 빌드 과정 없이 정적 파일을 실행할 수 있습니다.

```bash
python3 -m http.server 4173 --directory dist
```

브라우저에서 `http://localhost:4173`을 엽니다.

## 상태

현재 버전은 제품 흐름과 디자인을 검증하기 위한 프로토타입입니다. 로그인, 건강 앱 연결, 가족 간 동기화는 데모 동작이며 실제 의료 진단을 제공하지 않습니다.

Supabase 데이터베이스와 가족방별 접근 제어는 구성되어 있습니다. 다음 단계에서는 실제 소셜 로그인과 화면의 가족방·건강 기록을 Supabase 데이터에 연결하고, 개인정보 보호 및 계정 삭제 흐름을 추가합니다.
