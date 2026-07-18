# LANraragi Nitro

LANraragi Nitro는
[LANraragi](https://github.com/Difegue/LANraragi)를 기반으로 reader 사용성,
library workflow, duplicate review, deployed reliability를 개선한 개인용
feature fork입니다.

[English](README.md) · [Upstream project](https://github.com/Difegue/LANraragi)

## 주요 변경점

- Paginated/double-page reader, adaptive spread alignment, session-aware
  navigation, fullscreen control, 선택적 blank-border crop 개선
- 빠른 library rendering, selection 및 bulk action, responsive archive card,
  page reload 없는 deletion refresh
- Versioned fingerprint, focused comparison queue, 안전한 archive 처리를 갖춘
  cover 중심 duplicate review
- 대규모 deployed library를 위한 Redis, archive ingestion, thumbnail,
  reader cache, request hot-path 안정성 개선
- OLED variant를 포함한 추가 Catppuccin theme

## 호환성

이 저장소는 LANraragi `dev` branch의 변경을 주기적으로 반영합니다. 기본
설치, 설정, plugin 개발 방법은 upstream과 동일하며, base application에
관한 내용은
[LANraragi 공식 문서](https://sugoi.gitbook.io/lanraragi/)를 참고하십시오.

이 저장소는 독립적인 fork입니다. Upstream project에 issue를 보고하기
전 upstream LANraragi에서도 동일한 문제가 재현되는지 확인하십시오.

## License

LANraragi Nitro는 LANraragi의 MIT license를 유지합니다. 자세한 내용은
[COPYING](COPYING)을 참고하십시오.
