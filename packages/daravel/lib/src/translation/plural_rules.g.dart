// GENERATED from Laravel 12's MessageSelector::getPluralIndex
// (MIT; the rules come from Zend Framework, new BSD license).
// Do not edit by hand.

/// The plural form [number] takes in [locale] (Laravel's
/// `MessageSelector::getPluralIndex`); unknown locales use 0.
int pluralIndex(String locale, num number) {
  final n = number.toInt();
  switch (locale) {
    case 'az' ||
        'az_AZ' ||
        'bo' ||
        'bo_CN' ||
        'bo_IN' ||
        'dz' ||
        'dz_BT' ||
        'id' ||
        'id_ID' ||
        'ja' ||
        'ja_JP' ||
        'jv' ||
        'ka' ||
        'ka_GE' ||
        'km' ||
        'km_KH' ||
        'kn' ||
        'kn_IN' ||
        'ko' ||
        'ko_KR' ||
        'ms' ||
        'ms_MY' ||
        'th' ||
        'th_TH' ||
        'tr' ||
        'tr_CY' ||
        'tr_TR' ||
        'vi' ||
        'vi_VN' ||
        'zh' ||
        'zh_CN' ||
        'zh_HK' ||
        'zh_SG' ||
        'zh_TW':
      return 0;
    case 'af' ||
        'af_ZA' ||
        'bn' ||
        'bn_BD' ||
        'bn_IN' ||
        'bg' ||
        'bg_BG' ||
        'ca' ||
        'ca_AD' ||
        'ca_ES' ||
        'ca_FR' ||
        'ca_IT' ||
        'da' ||
        'da_DK' ||
        'de' ||
        'de_AT' ||
        'de_BE' ||
        'de_CH' ||
        'de_DE' ||
        'de_LI' ||
        'de_LU' ||
        'el' ||
        'el_CY' ||
        'el_GR' ||
        'en' ||
        'en_AG' ||
        'en_AU' ||
        'en_BW' ||
        'en_CA' ||
        'en_DK' ||
        'en_GB' ||
        'en_HK' ||
        'en_IE' ||
        'en_IN' ||
        'en_NG' ||
        'en_NZ' ||
        'en_PH' ||
        'en_SG' ||
        'en_US' ||
        'en_ZA' ||
        'en_ZM' ||
        'en_ZW' ||
        'eo' ||
        'eo_US' ||
        'es' ||
        'es_AR' ||
        'es_BO' ||
        'es_CL' ||
        'es_CO' ||
        'es_CR' ||
        'es_CU' ||
        'es_DO' ||
        'es_EC' ||
        'es_ES' ||
        'es_GT' ||
        'es_HN' ||
        'es_MX' ||
        'es_NI' ||
        'es_PA' ||
        'es_PE' ||
        'es_PR' ||
        'es_PY' ||
        'es_SV' ||
        'es_US' ||
        'es_UY' ||
        'es_VE' ||
        'et' ||
        'et_EE' ||
        'eu' ||
        'eu_ES' ||
        'eu_FR' ||
        'fa' ||
        'fa_IR' ||
        'fi' ||
        'fi_FI' ||
        'fo' ||
        'fo_FO' ||
        'fur' ||
        'fur_IT' ||
        'fy' ||
        'fy_DE' ||
        'fy_NL' ||
        'gl' ||
        'gl_ES' ||
        'gu' ||
        'gu_IN' ||
        'ha' ||
        'ha_NG' ||
        'he' ||
        'he_IL' ||
        'hu' ||
        'hu_HU' ||
        'is' ||
        'is_IS' ||
        'it' ||
        'it_CH' ||
        'it_IT' ||
        'ku' ||
        'ku_TR' ||
        'lb' ||
        'lb_LU' ||
        'ml' ||
        'ml_IN' ||
        'mn' ||
        'mn_MN' ||
        'mr' ||
        'mr_IN' ||
        'nah' ||
        'nb' ||
        'nb_NO' ||
        'ne' ||
        'ne_NP' ||
        'nl' ||
        'nl_AW' ||
        'nl_BE' ||
        'nl_NL' ||
        'nn' ||
        'nn_NO' ||
        'no' ||
        'om' ||
        'om_ET' ||
        'om_KE' ||
        'or' ||
        'or_IN' ||
        'pa' ||
        'pa_IN' ||
        'pa_PK' ||
        'pap' ||
        'pap_AN' ||
        'pap_AW' ||
        'pap_CW' ||
        'ps' ||
        'ps_AF' ||
        'pt' ||
        'pt_BR' ||
        'pt_PT' ||
        'so' ||
        'so_DJ' ||
        'so_ET' ||
        'so_KE' ||
        'so_SO' ||
        'sq' ||
        'sq_AL' ||
        'sq_MK' ||
        'sv' ||
        'sv_FI' ||
        'sv_SE' ||
        'sw' ||
        'sw_KE' ||
        'sw_TZ' ||
        'ta' ||
        'ta_IN' ||
        'ta_LK' ||
        'te' ||
        'te_IN' ||
        'tk' ||
        'tk_TM' ||
        'ur' ||
        'ur_IN' ||
        'ur_PK' ||
        'zu' ||
        'zu_ZA':
      return (number == 1) ? 0 : 1;
    case 'am' ||
        'am_ET' ||
        'bh' ||
        'fil' ||
        'fil_PH' ||
        'fr' ||
        'fr_BE' ||
        'fr_CA' ||
        'fr_CH' ||
        'fr_FR' ||
        'fr_LU' ||
        'gun' ||
        'hi' ||
        'hi_IN' ||
        'hy' ||
        'hy_AM' ||
        'ln' ||
        'ln_CD' ||
        'mg' ||
        'mg_MG' ||
        'nso' ||
        'nso_ZA' ||
        'ti' ||
        'ti_ER' ||
        'ti_ET' ||
        'wa' ||
        'wa_BE' ||
        'xbr':
      return ((number == 0) || (number == 1)) ? 0 : 1;
    case 'be' ||
        'be_BY' ||
        'bs' ||
        'bs_BA' ||
        'hr' ||
        'hr_HR' ||
        'ru' ||
        'ru_RU' ||
        'ru_UA' ||
        'sr' ||
        'sr_ME' ||
        'sr_RS' ||
        'uk' ||
        'uk_UA':
      return ((n.remainder(10) == 1) && (n.remainder(100) != 11))
          ? 0
          : (((n.remainder(10) >= 2) &&
                    (n.remainder(10) <= 4) &&
                    ((n.remainder(100) < 10) || (n.remainder(100) >= 20)))
                ? 1
                : 2);
    case 'cs' || 'cs_CZ' || 'sk' || 'sk_SK':
      return (number == 1) ? 0 : (((number >= 2) && (number <= 4)) ? 1 : 2);
    case 'ga' || 'ga_IE':
      return (number == 1) ? 0 : ((number == 2) ? 1 : 2);
    case 'lt' || 'lt_LT':
      return ((n.remainder(10) == 1) && (n.remainder(100) != 11))
          ? 0
          : (((n.remainder(10) >= 2) &&
                    ((n.remainder(100) < 10) || (n.remainder(100) >= 20)))
                ? 1
                : 2);
    case 'sl' || 'sl_SI':
      return (n.remainder(100) == 1)
          ? 0
          : ((n.remainder(100) == 2)
                ? 1
                : (((n.remainder(100) == 3) || (n.remainder(100) == 4))
                      ? 2
                      : 3));
    case 'mk' || 'mk_MK':
      return (n.remainder(10) == 1) ? 0 : 1;
    case 'mt' || 'mt_MT':
      return (number == 1)
          ? 0
          : (((number == 0) ||
                    ((n.remainder(100) > 1) && (n.remainder(100) < 11)))
                ? 1
                : (((n.remainder(100) > 10) && (n.remainder(100) < 20))
                      ? 2
                      : 3));
    case 'lv' || 'lv_LV':
      return (number == 0)
          ? 0
          : (((n.remainder(10) == 1) && (n.remainder(100) != 11)) ? 1 : 2);
    case 'pl' || 'pl_PL':
      return (number == 1)
          ? 0
          : (((n.remainder(10) >= 2) &&
                    (n.remainder(10) <= 4) &&
                    ((n.remainder(100) < 12) || (n.remainder(100) > 14)))
                ? 1
                : 2);
    case 'cy' || 'cy_GB':
      return (number == 1)
          ? 0
          : ((number == 2) ? 1 : (((number == 8) || (number == 11)) ? 2 : 3));
    case 'ro' || 'ro_RO':
      return (number == 1)
          ? 0
          : (((number == 0) ||
                    ((n.remainder(100) > 0) && (n.remainder(100) < 20)))
                ? 1
                : 2);
    case 'ar' ||
        'ar_AE' ||
        'ar_BH' ||
        'ar_DZ' ||
        'ar_EG' ||
        'ar_IN' ||
        'ar_IQ' ||
        'ar_JO' ||
        'ar_KW' ||
        'ar_LB' ||
        'ar_LY' ||
        'ar_MA' ||
        'ar_OM' ||
        'ar_QA' ||
        'ar_SA' ||
        'ar_SD' ||
        'ar_SS' ||
        'ar_SY' ||
        'ar_TN' ||
        'ar_YE':
      return (number == 0)
          ? 0
          : ((number == 1)
                ? 1
                : ((number == 2)
                      ? 2
                      : (((n.remainder(100) >= 3) && (n.remainder(100) <= 10))
                            ? 3
                            : (((n.remainder(100) >= 11) &&
                                      (n.remainder(100) <= 99))
                                  ? 4
                                  : 5))));
    default:
      return 0;
  }
}
