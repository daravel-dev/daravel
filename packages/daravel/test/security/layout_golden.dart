// Recorded from the regular expressions at c3cb4f5d with
// Random(20261113): footer, subcopy, and the sha256 of
// MailTheme(appName: 'App', footer: footer).layout('<p>b</p>',
// subcopy: subcopy).
const layoutGolden = <(String, String, String)>[
  (
    '</a><td><thead></x-mail::button>< <p <thead>',
    '<tablestyle="data-k="v" <p><img <img "<p ',
    '5e6225b962e30e60a9916f9d7988579b47c38ad0b478d9b3aa69180035012f9e',
  ),
  (
    '',
    '<a "[l](t)<img </a>',
    'd52ee26bd3f1a88de20aa7f292550885bd253538bbba9dfd90d0ed112798be1f',
  ),
  (
    'x><a </x-mail::button><h10<a href="h"><-**',
    '</x-mail::button>"<',
    'c196ba8610cdd415d47e2dfb172c64e12393afe3701b7c8471e49ca592104838',
  ),
  (
    '<=</a>><a href="h"><thead>\n[l](t)<td>',
    'data-k="v" ',
    '6a8eba6d1c04730bc54e98492550597e0943a63b40f3c4a5f7eb4eef55356816',
  ),
  (
    '',
    '><>**',
    '1b024364292dc4dcb4c060b11f51b6b740f4eb846adb6e2094509b2a30a933dc',
  ),
  (
    'style="',
    '<img =<x-mail::button **a="b"</x-mail::button>',
    'e6739d9f31e94c99083e083101fe903fdc97673b90f0bab8424b55a2d385d27f',
  ),
  (
    '',
    '<h10</x-mail::button><thead><thead><<thead></x-mail::button></a>',
    'a717c324dbbb01feb3ec9c5f0981b871aa0699bdbfb7c05682dc9bde99a38d4a',
  ),
  (
    '<p>-<h10<img ',
    '',
    '789d10f5052d821f91c475a8c3b2892497cffb9067e03c5920a65ee69fff57b3',
  ),
  (
    '</a></a> <p <x-mail::button url="u"><p **[l](t)<p>data-k="v" x',
    '<p><blockquote',
    '3c3eeb9502e2f839050412282d15b096d1c528658133ce20214f2a6dca7b59b7',
  ),
  (
    '</a><x-mail::button url="u">[l](t)</a>\n-',
    '<table=<thead>-a="b"<p -<h10<x-mail::button ',
    '433f3bbd88668dd53248fef3aae41373db495709685feee6ae8de042057df76b',
  ),
  (
    '><p <x-mail::button url="u">x',
    ' data-k="v" <a <a href="h"><blockquote',
    '57a5f7fb57498dbd30b32b35dede42575c88be8725ebf2cb165f94f30e2086b2',
  ),
  (
    'a="b"<a style="c">-**',
    '=<x-mail::button url="u"><h1<img <thead><td><h10',
    'fecb22d527fbfa767b0f01e8590ced1be925a8a0ab9b9024f5987a421f932620',
  ),
  (
    '<a href="h">**<p>data-k="v" <p>a="b"style="x<</x-mail::button>',
    '<h10""<blockquote<x-mail::button <p <a href="h"></x-mail::button>x<a href="h">data-k="v" ',
    '20356aec6c54add47bf15708feb8ae942731ba7c608883797b251e77685b781e',
  ),
  (
    '<p><h10<a style="c"></x-mail::button><a style="c">',
    '<blockquote>a="b"<x-mail::button url="u">data-k="v" <a href="h"><x-mail::button url="u">',
    '056b46718ca47fc5d6730a512e5786a2505a7779f91a9c09bedce47adde61e1b',
  ),
  (
    '<p>x<a href="h"><p><blockquote<td>>"-[l](t)<td>',
    '<<x-mail::button data-k="v" <table<img </a>style=" <a ',
    '4ea17be36181c0a861feb420bcf2411723bd2f41fddd1f1b1513b4b85303fa37',
  ),
  (
    'a="b"<a style="c">[l](t)',
    '<<a href="h"></x-mail::button><table</x-mail::button>[l](t)style="',
    '0b5b03e9e119218825aca8191d49d00836cda1ab3596ce31202d320d6afc7e98',
  ),
  (
    '<td>><<a style="c">',
    '',
    '35cc62afcc2d194cb87232f64437ee3795deea23c454dd18285ce6a035b28c12',
  ),
  (
    '"<td><p <h10data-k="v" <thead>\n**',
    '<x-mail::button url="u"><x-mail::button url="u">==<img <x-mail::button <<p data-k="v" <p>',
    '3de8d0af1f00d35294558c76ab0f162ac0205a6f96c1f56c122004301a9ada7e',
  ),
  (
    'style="**<p <h10<a href="h"><x-mail::button <blockquote',
    '</a><blockquote<a style="c">-',
    '4f218531c8e56ad84241db0afa34f6996f6812ea07f99d830c71abe7e0650b10',
  ),
  (
    '<p></a><a <a href="h"><a <a style="c">""',
    '=data-k="v" "[l](t)\n<a href="h">',
    '4024b6fed5e4e37d683951de89cbe95405de89f52e1ebdb583c4a415355f1b95',
  ),
  (
    '</x-mail::button>\n',
    '',
    'e704e4158e34b962967c0b89b68e2cdac19b765b4c39f9b3759f027e588f35ac',
  ),
  (
    '<td><p>=<h10</x-mail::button>style="',
    '<p><p><td><a style="c"> ',
    '0ac4ccf71207b7683370cc5209d1b810e3b4f275a3dabccf4a94e586ce49b74a',
  ),
  (
    'x"<p><x-mail::button <<p ',
    '<x-mail::button url="u"><x-mail::button <h10',
    'e6c942e2afb0fa1726ba5d8e209bfa0cfb99bdde6e4f7d2e254e7b209521fb20',
  ),
  (
    'x<table<table<table"<img <p <a = ',
    '',
    '82fd8f504911a0810bddb498dbc88de3f34fdd9b87fc031047155943965b49d8',
  ),
  (
    '<table<p ',
    '=<blockquote',
    'cc8f99d7ff3c81f8d2563dbe6c9e962c960fb3513522e5f2693248821ebd15f8',
  ),
  (
    '></a><a href="h">style="-<>',
    '',
    '9acf251f76299acd40fc994c5f5bddf97e75a4bbc15b65d009932004f15ad050',
  ),
  (
    '<img <a href="h">>',
    'x<a style="c">',
    '848cb34f04ecd1b02894abe4131273705f129e991fc90b70c431180b6fe3008a',
  ),
  (
    '<h10style="</x-mail::button><a style="c">a="b"<x-mail::button a="b"\n',
    '',
    '70a65b45b99391df26b1b6ad53eaa8b85c021d06dae430d1c21f9e089fe4b47a',
  ),
  (
    ' "style="<h1=-<x-mail::button url="u"><p>',
    '<<a style="c">x<h1<blockquote**',
    '6b9815f5fca00e2bb398c25ae7414f0ee8ac5474bda5c36876a1b49f07e12def',
  ),
  (
    '',
    '<x-mail::button <img </a>=',
    'b8b503c21691e20d1ef4e5b38a58fe8c6422271c0f3e7dbe93353de25742dbec',
  ),
  (
    'x<x-mail::button =\n><a ><x-mail::button >a="b"<a style="c">',
    'a="b"x"style="<p <p <img <h1',
    '803dd0bdcb6bc5b2bc5e27f9e01d77f0f982d63fd276abb636489a3e3d31b3d9',
  ),
  (
    '<blockquote"a="b"</x-mail::button><h10<a href="h"><blockquote>=<**',
    '<tablex',
    'f99c3608c7300c4905f7c1e279f953409f5810cf8488e8462e811a32c5be7b4d',
  ),
  (
    '<x-mail::button url="u"><x-mail::button <td></a><p><td><a href="h"><a href="h">=a="b"',
    '<a href="h">style="=<p>x',
    'a76944f46c793af8bcc1bf876093dd26acd3a8f1bfda6711696c47818afc3510',
  ),
  (
    '"',
    '><h1-',
    '81a1d16e7d465e6ff6a97824637ef81816c35370110a7f23dc979b33aa1fcc6a',
  ),
  (
    '<h10****style="',
    '<x-mail::button url="u"><thead><td>>>-</a>**<blockquote',
    'c738b1c273a8a15b35bf9a293ae39cb7a1d75760ecb4ef2994d428f2c4aebe0f',
  ),
  (
    '<x-mail::button url="u"><img <thead><thead>a="b"<table<p>a="b"\n',
    'style=""[l](t)<img ',
    'e53f328d58e39e50710e3edc0a0917c354da62c2df85e9e2bd58b26dfbd46d27',
  ),
  (
    '</a><h10x',
    '<img <h1<a ',
    '8ee4fb5e5a2be0bc07b4f86f47f8fc9f102df441c600c11043733893f18ae4fe',
  ),
  (
    '<p  ',
    '=<h10**<a style="c"><a style="c">x',
    '99240b5343808c6015ef6ed7dc2fced784cbe91638584c750fb4e73f367283c6',
  ),
  (
    '<img <a <table<a style="c"><thead><td>',
    'a="b"<a href="h">',
    'af35e9c2b73488c4e6220133cfc7b775f957f5b46f7766eb9e3c5338a59aed63',
  ),
  (
    '</x-mail::button>\n</a>a="b"[l](t)<a style="c"><td> <a href="h"><p><blockquote',
    '**</x-mail::button></x-mail::button><table',
    '84c8cad8b39c53aae5975080d659d6d105b6828780875ebfb6f38742978d2f00',
  ),
  (
    '<h10<a href="h"><a \n<h1',
    '<h10<tablea="b"<img **<x-mail::button a="b"',
    '6ed68aefa765b657f41474205716d9b941b1298109423bde39a8892c0d820134',
  ),
  (
    '<blockquote',
    '<x-mail::button url="u"><x-mail::button <thead><img <a style="c"><p </x-mail::button>>',
    '64cf14e5b01ecd7b7feffb0d2c47d65f4fa50a593fe89ab5ae7a7f9d79dd96bb',
  ),
  (
    '<a <td><a href="h"><h10<a style="c">',
    '',
    '337a4745afcc3a2a7689944229bd67e2f06c3cf81c055eb2f5add85c3f45c2e7',
  ),
  (
    '</x-mail::button><a href="h"><thead><td><<a href="h"><<img  <x-mail::button url="u">',
    '<h1 <blockquote"<h10',
    'edde046011f0223ae52f960db9464afbc7e31a526258ff25737d5716c3578b5d',
  ),
  (
    '"<p <table<<a <table<td>style="<table<a href="h"><h1',
    '<a ',
    '58fcd69aa3c37ca438961385e9b5110984095ef03229846896239cd42a522a3e',
  ),
  (
    '<a href="h">xdata-k="v" <table',
    '<p><h10"=data-k="v" <h1**',
    '07105a30a19dc0c1ff4814cb11eb33f41108462fe507acf7c6ec15417daf91ee',
  ),
  (
    ' =<x-mail::button url="u"></x-mail::button>\n[l](t)<p ',
    '<blockquote<a style="c"></x-mail::button></x-mail::button><p>-</a><td>',
    '68a77f45da550c46b15f7157d56c830ca7568e8496bfd44933a107e0a3cf8390',
  ),
  (
    '<a style="c">',
    '<img <p >',
    '0a6fb49134b8906f5b08493aca55dcfdb5f1e1c8bd7723d950b83800eb826974',
  ),
  (
    '',
    '<table-<thead>\n <x-mail::button url="u">>',
    '03c3a5bf03190b6416dcea26e68e8923a67a96135e482a13ab9001445df7e018',
  ),
  (
    '<<table<a **<h1-=<p>style="<x-mail::button url="u">',
    '\n<x-mail::button url="u"><x-mail::button ><\n\n"**<a style="c"><blockquote',
    '81ae07c117521d86aaef38f8fdca7cd43e795fcf81111de4513cc128e3775081',
  ),
  (
    '><x-mail::button url="u">',
    ' <x-mail::button <h10<x-mail::button x<a href="h">data-k="v" <a ',
    'baa0b04e88b1950e3b367b284754ce7d3fc2674c5928a0a2f1782a3c83e5373c',
  ),
  (
    '<</a>=style="</a>**<a </x-mail::button>\n',
    '\nstyle="',
    'e1388727f565e44bfc2be37a9ed7b9bd444546eac9e812373f4d1948479796dd',
  ),
  (
    '',
    '<a href="h"><x-mail::button url="u"><table**<a style="c"><h1<td><thead>"<x-mail::button </a>',
    'c4a7306eef49664771f12cd0cc3c4e018dbb78a070c63900c902e0c87e5b6994',
  ),
  (
    '<thead>',
    '\n',
    'f6d5b9376a0c0843cdb4ee915e0e2f3dc633a61f1eab85c9826935466bb3b9b4',
  ),
  (
    '<table[l](t)<table<p <x-mail::button "<x-mail::button <a style="c"><td>',
    '<',
    'c1e13d2cf6222fa24d20bf53ed4f39ae2db3e13678ed479764be5e730a30065b',
  ),
  (
    '=</a>x"->',
    '<</a><h1<a href="h">',
    'a6b35e8db723bf2bbab869335899af620f6320e1cdc1f4e9ba3ac7bcf812c1a7',
  ),
  (
    '<p <thead></a>[l](t)**\n',
    '<img <p><h1<a href="h"><p><x-mail::button x<img "',
    '802df13c8ab670f8d55fba127802e012a1926c57cbfe5485877ed795bc4d70ba',
  ),
  (
    '<<x-mail::button url="u"><p **<a href="h">style="x<x-mail::button url="u">',
    '<a <<blockquote<td><img <blockquote"data-k="v" <p <a ',
    '810d6d8ea52720dd6d370a9f2a86a8ae9396348de339509cc5a89c839f8aed25',
  ),
  (
    '<table<x-mail::button url="u"><a style="c"><h10<a href="h"><table',
    '\n--<img <a style="c">',
    'eaa0aee37810291974c01321a69dbaae52a018a88c8ca62aee423ab9a91ce6af',
  ),
  (
    'a="b"</a><img <x-mail::button url="u"> <a style="c">data-k="v" [l](t)>',
    '> <a style="c"><h10<a href="h"><h10data-k="v" <',
    '490bcc1093bbcaddcdf714722977270c31f8199c01fb91de8508b25ff979448e',
  ),
  (
    '<img style="<p>=data-k="v" ',
    '<a a="b"<x-mail::button <td><a href="h">',
    'a07c508efb92d894e45d38b5da85a10461153d15af9da1029e0e2339827bc6d4',
  ),
  (
    ' <thead><p>',
    '<p <data-k="v" ',
    '3b063d4abad8ef25e2dec2cea51e5d5c364caed68e956ed91e587cbab22eab66',
  ),
  (
    '<h10<</x-mail::button><a style="<table**\n[l](t)<',
    '<p><p><a href="h"></a><x-mail::button </a></a>',
    'e6baa3a87a88c9b26838fab0c0d25deafe07a9c1e9c43c18d413205ca7c58f18',
  ),
  (
    '**<td><p </a>"<\n<table',
    '<h1<img <h10=',
    '25d73c5f8c5c519fade1e6e7178c430b201f100255293a5c4e027657c125f1ba',
  ),
  (
    '<h10<img style="<a style="c">data-k="v" </x-mail::button><td>-',
    '=style="<a style="c">a="b"</a><td>[l](t)<a style="c"><a style="c">-<a style="c">',
    'e9d8d07a6b10ce14331f5c8b026163338043f478be0b77aa24ec4d5705bc557f',
  ),
  (
    'a="b"<h1<td></a>',
    '',
    '7bcda4140ea9c32699eab18e00fd86248c21ef03b06ebc8d0c45c5240a520af2',
  ),
  (
    '<a="b"<img <a "<blockquote<td><a style="c">',
    '</x-mail::button>>',
    '562147d0379030c7d1d44655336a4027abb9dde5eb78fa2697a7277e02946082',
  ),
  (
    'a="b"style="',
    '->**style="',
    '2df99355b42dc6ca993f79f171bc35980c24f972c20255279002c161eccbb2bd',
  ),
  (
    '<thead><a style="c"><table<thead>style="<p <td><x-mail::button <blockquote',
    '\n><"<p><blockquote</x-mail::button><p><</a><p>',
    '44c8183d362156c029a8c0a1b2fd49cb31dccc637396740e8a1c20de60c6b3d8',
  ),
  (
    '<thead><td><blockquote</x-mail::button><x-mail::button <h1',
    '<a x<h10<a </a><a style="c"><td>a="b"-<a <x-mail::button ',
    '5175636debe15b549f31cfbe254ffb1a1db5e73a233f922f05d8d07c1a525bce',
  ),
  (
    '</x-mail::button>\n<a href="h"><p><a href="h">',
    '<x-mail::button ',
    'e6d8aee2c41c2d478ef000ab7bb7914413ea5b3256f0f42757dd2acb42ea395b',
  ),
  (
    '<img <thead>style="<p <table<a href="h"><p ',
    '<x-mail::button <h1-<td>[l](t)',
    'd8876ef4f80b023f1f9d5d5f04f2aec1e8581432c4a4c4c1f03474350baa4eca',
  ),
  (
    'a="b"<a <x-mail::button url="u">xa="b"<img <td><tabledata-k="v" x',
    'data-k="v" xx',
    '67cfbea720b9190fd41c927be33e7be5cff61a0856b45d24184636967d59d736',
  ),
  (
    '<p -x',
    'data-k="v" ',
    'd30fc862e7d078f7f8ba0bbaa4458ea6aa6efd63cc3769e187260630293eb7b8',
  ),
  (
    '<blockquote<thead>><td><blockquote</a><h10<td>style="',
    '**<a style="c"><blockquote<h10\n',
    '2654b594e93347a35ad68770acbd15c908b2c52806b0bb3414e627efbecc883c',
  ),
  (
    '[l](t)**<a href="h">xx',
    'data-k="v" \n<',
    'd7666fe70b3c04889ce9791ccc216999e6dc63fec5d1afc7855fcaec2de1f2dd',
  ),
  (
    '',
    '<a href="h"></a>=[l](t)>><p <',
    '02e9bc9a090de582a3fe8ed5490c7f8df0488432c7774878311a52fe296156ac',
  ),
  (
    '<tablea="b"-',
    '"',
    '2bedfa796b70803af19cb584ba5c3d431930b346ed61426ef79b4ffb7f8050e9',
  ),
  (
    '<a href="h">style="</a>xa="b"',
    '<p><a style="c"><a href="h">**"<td><a "<p>style="<img ',
    '01cd036698451b2517c726035fcf96efcd94d4363941c071b491a4919513307f',
  ),
  (
    'style="[l](t)<x-mail::button url="u"><x-mail::button url="u">',
    ' <a style="c"> >-<h1',
    'a9d46ce0f58a34baaf42d3c0df8ea738d1c963b944a55fed9c7aed033c9badd2',
  ),
  (
    '<thead>[l](t)<tablestyle="',
    '<data-k="v" <td><h1<table<a style="c"></x-mail::button>[l](t)\n>',
    '263f79e853de124830458286c6214cf777ee848dfbf84b6835cdb68a5d1bcf53',
  ),
  (
    '<x-mail::button url="u">data-k="v" ><blockquote',
    '<a href="h">>\n<p>**',
    'a05a7535262ec9f0a7b2b89aa83faffd09b9b5164517b07de7d73f7e6b49964d',
  ),
  (
    '<h10<thead>[l](t) [l](t)**</a>',
    '<a <h1<blockquote "<<p data-k="v" </a><a href="h"><p ',
    '4b0430dfc8cfb36ef4671b62f7621b70731618df0c59002ee117dfe6359fa472',
  ),
  (
    '[l](t)data-k="v" ><a ',
    '<td><x-mail::button <blockquote-<a style="c">=<h10',
    'df555c56d7f8f39a73e236db0638e14e93fe32e586d513675c325db6c63e8a47',
  ),
  (
    '',
    '><h1</a><x-mail::button url="u">-><thead>-',
    'e3a6c35a8edb56cecb0169aae105a3b0da8d3d764d76199c16fecc702fd95388',
  ),
  (
    '<"<h1<',
    '=data-k="v" </x-mail::button><<a style="c"><<x-mail::button data-k="v" ',
    'ebf61dfa55950e06dc31c5b68fe44a8aee7a4e7753e427ac68d58f47e2401e76',
  ),
  (
    '',
    '\nstyle="<x-mail::button url="u">',
    'd8cceb1cf7b0026bdad61cba89f4cb79a430755d811c209d0a44be60ee81677d',
  ),
  (
    '"a="b"\n<p><=a="b"',
    '<a style="c"><h10\n**style="<a href="h">data-k="v" x</a><p>',
    '86933e5f5539f986dddb8a23f1fb1f59ce6421ae7d846233a478cb277177a171',
  ),
  (
    'x-<h1</a><a <a x</a><img <table<h1',
    '<<x-mail::button ',
    '4c3c9ddf0349369886a9362934723c859b161ce32b1aacf93f7a08e8ae2424e0',
  ),
  (
    'style="',
    '<<a style="c"></x-mail::button>-"[l](t)',
    '30394bd4fd3af2375d12382e479e1d8b68d35bb31d53d1ee750e65a797979f2f',
  ),
  (
    '<h10<img "**a="b" ',
    'style="<a style="c"><h1-<x-mail::button url="u">x<blockquote</a>****',
    '4b733f609ef8b7e6180ee203a4d8676ea0eda16af7eac96e40056b5f317aa6ba',
  ),
  (
    '<thead>[l](t)',
    'data-k="v" -',
    'ce6a3809c6b67e6ec06dbc69d36435ed48041c3fe97c908f815ccb2764c72279',
  ),
  (
    '<a href="h">x',
    '<x-mail::button url="u">**</a><p><thead><table',
    '44ca97df41971d64ddd39bbcf9a1046974ca31a8edcea65904486ef46e6d7df7',
  ),
  (
    '',
    '<a href="h"><a style="c"><td>===<table"<a style="c">style="',
    'f14ea48d62e4540c10e0cfafeb97edfdb35b10fbae1132ef54a5dcf30242b964',
  ),
  (
    '<p data-k="v" a="b"<table',
    '<x-mail::button url="u">"<h10<',
    '9cafdce5330f20af7a047548f6775e635dc1351caab95b7a43c9ba6b40bde2a0',
  ),
  (
    '"[l](t)</a><h1a="b"<blockquote',
    '<x-mail::button <table<td>',
    '72265e4b9e7097d1155cf8a4c7c5fbc61e8eb9236468129833c24711b8bcfa01',
  ),
  (
    '</x-mail::button><',
    '<a <td><a <x-mail::button url="u"><table- </x-mail::button>**<img ',
    '973afde9418ed254275b4c20156521f6e08723f2dd2569deb1d9de386fffc37e',
  ),
  (
    '',
    '=<h10<h1</a><blockquote<td>',
    'f2fdf946497055bc8cf2669e80152df907aed06f3320173433eb0d70c7454364',
  ),
  (
    '',
    '>=</x-mail::button><thead><table</a>\n<x-mail::button url="u"><a href="h">',
    'bec007056b5661485ebf90796059a8610d85b4b2fe2e94ae3833b77ff6c6401b',
  ),
  (
    'x<td><h10x<h1><h10',
    '<x-mail::button "**<h10style="',
    '17d58282d399774784756f95352db337bd2e05a9fdf4a823330a6162694f70c7',
  ),
  ('', '', 'ede2289fe46e088cb3dd59b72a2f2f5fbfc139b98972d026be9249d2f011727f'),
  (
    'data-k="v" <h10',
    '<a style="c"><a style="c">data-k="v" -<a style="c">-<a style="c"><a href="h"></x-mail::button><table',
    '04f8f87085a04ac10a4bde559136d10b89003e2be392810c1fa09aca43e6e058',
  ),
  (
    '</x-mail::button><table',
    '<p \n<img style="<x-mail::button </a>=\n</a>',
    '98bd16bfe842ddb7cc514798442fec67e3da9d33f5d91b6bfab3c117381d103b',
  ),
  (
    '"x**',
    '><h1</a><x-mail::button style=" ',
    '9aa1f1cd6e9c86b9f7b396849068780e823f8446643e20777d29a5ca1bc38af1',
  ),
  (
    '</a>',
    '<h10[l](t)',
    '4e716bef89b6c07393071fb7498ab6051c44e0c994c983a082542485eaea0bc9',
  ),
  (
    'style="<img <a style="c"><img ',
    '<table**<a style="c"></x-mail::button><a <table\ndata-k="v" <tablea="b"\n',
    '4f5ff8119ffe2c437643572b4fe5700a9de76bd2cf49190a3ebd3fedc924b9b0',
  ),
  (
    '<x-mail::button url="u">\n"',
    '<a <h10<table',
    '6f632dd2a8baa57f461146ee330f1352aa131146b663197e7b5ee2f5be00cc17',
  ),
  (
    '<x-mail::button url="u"><x-mail::button url="u">[l](t)<style="<a ',
    '<h1\n<thead>**<img "data-k="v" <img <img x',
    'b240c22451793668082b195f7708f51c20dbeab7d121fb246c186d4726ffb549',
  ),
  (
    '<a "',
    '<h1',
    '6724657eeabae54d5d83f2f834ffd8f03f810674a9601764c901139d6d7f444d',
  ),
  (
    '<a style="c"><a href="h"> </a>><p -',
    'a="b"<x-mail::button data-k="v" <a <table<h1',
    'f81450b31c04f5fc105d4fd11d4090cb9e78a1b9654741b0667fd476fd6ea52f',
  ),
  (
    '</a>a="b"<a href="h"><h1\n\na="b"x',
    '',
    '4ac1a0858274625d057fc22a68e14c81f5533c34afaf40652d719a09fae1e0df',
  ),
  (
    '<table<a href="h"><a "-**<thead><td>',
    '<a <a style="c"><td><h1**</x-mail::button>',
    'f9fefe83e2dea58bcc930b070707af441f854302add02c17874963667190f319',
  ),
  (
    '<p =<x-mail::button ><img a="b">**<a data-k="v" ',
    '<->=\n',
    '8ef8756f147c4ee263bbcc75db50d932909775a2c2d0f247987eb6a74642fda1',
  ),
  (
    '<thead><x-mail::button url="u"><table<a style="c"><x-mail::button url="u">',
    '\n<a href="h"><a style="c">x =<a href="h">',
    'c3d2bc7d3ad126671eb94453fefa31bdbf6540b909566ab853ac21e655af2a3f',
  ),
  (
    '[l](t)<img <blockquote<blockquotestyle="<blockquote=<img "<p [l](t)',
    '-<a style="c">a="b"x</a><h1<blockquote>x',
    '24eb7d6b567ddb0ada57088bc7b2f9ddd1404f0c93ce5351b36fced56981f96b',
  ),
  ('', ' ', 'ede2289fe46e088cb3dd59b72a2f2f5fbfc139b98972d026be9249d2f011727f'),
  (
    '<p <a style="<h10"xa="b" ',
    '></x-mail::button>></x-mail::button><p <p **<td><table<thead>',
    '562a937f6e13fbcc746fed7c34bbadb78e7ee4c8a4cbc9ab537d16648a3e2322',
  ),
  (
    ' <a  <a style="c">style="<p **',
    '<p><a =<table [l](t)<thead><table>"a="b"',
    '4a416ab7ec46b9f5eb1124f4ed00837a4bad2ac3bf26b515f0d699b67e07b58c',
  ),
  (
    '<a **<tablea="b"<p <a data-k="v" </x-mail::button><h1<td></a>',
    '<p <img **style="a="b""',
    '86fb5878c6cde3c5a3bc76bd7acafdd9b6dedf982f26347128bc52efd2c732e5',
  ),
  (
    'data-k="v" "<p \n<td></a>',
    '</a>',
    '29380312f8a7c5670b66dbcf15d5e4547bb9f1fdf3abb55a35b733c4a10e0e13',
  ),
  (
    '<table\na="b"<a style="c">-<p ',
    '<<a style="c">data-k="v" <img <h10**',
    '6e4c340bd3e5c37e7b579c9901a264da36a0233fcd6e30c56627da5c4faabff5',
  ),
  (
    '-<x-mail::button <x-mail::button x',
    '<thead>',
    '895e3d28aa4eed13acc8ae5c5e4dfd1a8a295e5060ee977c048aba0b3bf91291',
  ),
  (
    '</a>style="<img ',
    '</x-mail::button><table**',
    '8590d94f57f35ad9dfada0be8b40bf82190f14702920dc92809c18589fe43aae',
  ),
  (
    '<blockquote</x-mail::button><h1',
    '**</a></x-mail::button><h10<blockquote<-xx<h10<a ',
    '6238ef898d82e8ebe513e0ea5a57715388745d8f19a127f54e4428cb7a13bfb7',
  ),
  (
    '<<h1<a style="c"><a style="c"><a style="c">',
    '<',
    '56030ee2681eb8a4bb05187e9112c4ba15c4badc150a93f583d81a2419247aee',
  ),
  (
    '<style="<table<img -x[l](t)<x-mail::button url="u">',
    '<img <blockquote',
    '60d148f96a5bbe27e112912bbff0bf3556b85d2af6626f9bbfefd75d6d6c961b',
  ),
  (
    '\n</x-mail::button></x-mail::button><a </x-mail::button>>[l](t)<p <x-mail::button url="u"><img <a style="c">',
    '<blockquote',
    '5977e28f0c10e36c7a8ec9d08e63103ab9681ea956fbed8fdf2e17507984a232',
  ),
  (
    '<thead><blockquote"x</x-mail::button><p **x',
    '',
    '697c00632513918654c5fb502a9623f8eb2d5eaed12c1cfb168d59f0ca1b4e21',
  ),
  (
    'style="',
    '<p>\nx =<a style="c">\n<a style="c"> ',
    'd2ceeb156e956a31d4a10b80283f8a369125a0ea04d11e4a88701bb588b4bd65',
  ),
  (
    '<h1<h1**<td><<blockquote<p **-><x-mail::button url="u">',
    'a="b""',
    '2bf1e9760285b3be183c33618bf0060321902faac3acb7cf060f2021603a41b7',
  ),
  (
    '<h10</x-mail::button><h10<a style="c"><thead><td> ',
    '',
    'e534f717514013ce709ea36aba6c28b0b96dcc7df9c12c6df5b92f65b2e03f48',
  ),
  (
    '[l](t)<p data-k="v" <a style="c">data-k="v" <p <td>><img ',
    '"<<"<h1 <p><<tablea="b"',
    '7d7c4fc9635a975010810b2846469963baf0ce4cd01ffba3124b4cda94302ded',
  ),
  (
    '><img <h10',
    '<x-mail::button =<a href="h"></a><blockquotex<a href="h"><img -<p><thead>',
    'ec0781ffd0677c94f154bc4fc218cfd51da2e3e25f17691b946bc3fde05d6e86',
  ),
  (
    '<<a style="c">',
    '</a>><thead><td><a </a>',
    'f8bde5d9e408a365fcd00681b1f2e70c91200f0f56e0fcb224a88160042455e5',
  ),
  (
    '->>a="b"<blockquote<table',
    '<p>',
    '6c392effc62b37136540da141158b15d96f8fa090b00e7b634f69c5b7193a268',
  ),
  (
    '"[l](t)-<x-mail::button url="u">-',
    '<a href="h"><x-mail::button url="u"><h1<p></x-mail::button>\n=',
    'bd8723345ccd57bc30028711c3eaebfdc2aacb47dda5286d7a3009e91c5efd73',
  ),
  (
    '<h10"<a style="c">',
    '<p <tablestyle="<thead>x<a href="h">data-k="v" <x-mail::button url="u">',
    'fd72e962d6881abfd3f07d6a824da6379e3859ffa909c57d22fde7e1f78baf2a',
  ),
  (
    '<x-mail::button url="u"><a ',
    'a="b"<img  ',
    '316e584056cd8868ee47eecb26c4223385f06ecdea8c64e76542565dc8cc85d4',
  ),
  (
    ' \n[l](t)x<a href="h"><><p>',
    '<a href="h">a="b"<p>data-k="v" **<a <blockquotea="b"',
    'bb32e8cb1c235024a37357cd298db411f73706295cc353a00bc133cd24c43447',
  ),
  (
    '<a <h10x=',
    'x"<thead>a="b"style="<p <x-mail::button <data-k="v" </a>style="',
    '74a976a24eb92afe5c86e4d27486af6732be132696706c109b9ff72056244cd5',
  ),
  (
    '</a><<table <h10->',
    '-<x<td><thead><a ',
    '0da356ef848c23fb2ae7d76cb3ede02fe42f9dcba4b7ee05db19ea4dd6376188',
  ),
  (
    '<h10-<img ',
    '<</a>x<a style="c"><h10',
    'a0150ba6a9ba59dfbde1f444d7ebbd768776eadd207c3e3065298ab6df322ec6',
  ),
  (
    '[l](t)<x-mail::button <a <x',
    '<h1<p>="<x-mail::button <',
    'a856e1697e2566f534321c389251064b527816de987198e70c600273ef6db298',
  ),
  (
    '<thead> a="b"<h10<a \n<x-mail::button data-k="v" style=" <h1',
    '<img [l](t) "</x-mail::button><a style="c">[l](t)',
    '0e0c633f84917535b29904cbebff8d91c857ebcbf369f3ed362e46d79b6c6f89',
  ),
  (
    '<thead>',
    '<p>-<</x-mail::button>',
    '5091bacba50733a4db32c32deec4ff0281134f87eeb6f4b68e41a2796c5dd855',
  ),
  (
    '<table <img <blockquote<p a="b"=="<a href="h">',
    '<td>**<td><p><thead><a style="c">x**"<a style="c">x',
    'b19535c6d18d2dc16f308edf14e76d5846379dd0eefaca5d09275850baa88157',
  ),
  (
    '<a <<img =>style="<thead><a style="c">',
    '<x-mail::button url="u"><thead><p><img "=[l](t)=<td><a <a style="c">',
    '9f9002778915b20ea1289cdcafaba39a9fe2528a51dfc19d5a21ceb5879f59e1',
  ),
  (
    '<h10-',
    '<h1<h10><thead>=<p><table><a href="h">**',
    'd6f7159cb9c8eb7b9e4ce447bc98c440cf4e4268fc8a78649c9f57dc760eed30',
  ),
  (
    '<h1<x-mail::button url="u"><img <img [l](t)"',
    '<table>xdata-k="v" =<a href="h"><img [l](t)',
    'a15848883ab5761d7e5640694ed2fb68bacb04b00f6486cd8183fd9057abaef3',
  ),
  (
    'a="b"a="b"<<p <table[l](t)<x-mail::button <img </x-mail::button>',
    '<a style="c"><thead>data-k="v" \n',
    '8308427e0d6cf391edb4c9674d52c91f2a9392a4cb42c22a5f4ecfddb6ee1a3d',
  ),
  (
    '<thead>"\ndata-k="v" data-k="v" <p <blockquote<h1<p>data-k="v" <',
    '</x-mail::button>>[l](t)<a href="h"><h10"**',
    '982fd937edf9b2ba554c17952ecfe44fd473fa5ad178e623ef2f60ba9481bad2',
  ),
  (
    '><',
    ' data-k="v" </x-mail::button><a <x-mail::button ',
    '5770d0234ac2b5ccdccbef88f0b6aa213b282278218f4b415c88982c2556c563',
  ),
  (
    '<x-mail::button url="u">><td>data-k="v" ',
    '<td>"<<a href="h"><x-mail::button url="u">',
    'cdf64846fa9f99d6b825b223be6a825beeb54e9092706ae79af4d50f2a0b9b14',
  ),
  (
    '<img >-style="<h10style="[l](t)',
    '-',
    '4c8bcf0cd4d148d00620e6e652efeac79c548802bcccc2d90944fa261115f438',
  ),
  (
    '</x-mail::button>[l](t)-<blockquotestyle="',
    '',
    '5d8a29bc527700c8d066154b574ecb445081bf224cec9a2e1e871dfb0b9d4289',
  ),
  (
    '</a><img <td><table<h10<blockquote>**',
    '<p <a <h10\n**<a href="h">',
    'a0dbcf5155717641e12204de31b6b034decda8557daf7c89f3df325c8734fb40',
  ),
  (
    ' <p <p>style="',
    '<<img <p <h10<a style="c"></a>>\n</x-mail::button>data-k="v" <blockquote',
    '11de3a373b28a72024d5f02d67eb68ff8ed7730e76090b3b7e756696ae088a77',
  ),
  (
    '<p>',
    'a="b"data-k="v" <x-mail::button url="u"><a style="c"><blockquote><h10"** data-k="v" ',
    '0aa12a0ba0072581249977857d694921b8546875a9fab6097d27e799c158774a',
  ),
  (
    '<x-mail::button <"<thead><table</x-mail::button>><td>',
    '',
    'd9d704ef7873c08261eeceedb57c2f601fe9eb4ba9bd382bfc796a1a856ee13b',
  ),
  (
    'x>a="b"<blockquote<blockquote<a style="c"><a style="c"><x-mail::button >\n>',
    '<a "<thead><a href="h">x',
    '204c809affc698caac0a179f6961e2b804c8f2e0bb1bc910718adcac9a7fef52',
  ),
  (
    '<table\n<thead>\ndata-k="v" <table<blockquote',
    '<table<a <a href="h">-<td><p ',
    'edf4b45d6c11ee0c7eecbc33ee35be82ddae36c9c17c61217d49efd94edf2b98',
  ),
  (
    '</a> <x-mail::button url="u"><blockquote<x-mail::button url="u"><x-mail::button url="u"> x<thead><x-mail::button >',
    '<<p><a <h10<h1<',
    'b78616dd82b252b91aa565f9de01698bb90fdbbf5a0a7aad8e0e032a0af950e7',
  ),
  (
    '</a><a <a style="data-k="v" <',
    'a="b"<a href="h"><h10<x-mail::button  <p><a href="h"><h1',
    '078ddffe94e74e7cb70b4678aca4509e05e851242572afe6402df6500e9d45f1',
  ),
  (
    '<blockquote=-<a style="c">**<td>\n<td> <x-mail::button url="u">',
    '><thead>',
    'e400d86132cf936842a88e4527d88511b98d59120006dfe6b7da434d7e21a97f',
  ),
  (
    '</a>-<h10a="b"<a <a href="h">a="b"<table',
    '<p>x<<h10<h1<h10[l](t)<x-mail::button ',
    '188a0896c8d94cad680b4c182c1314b5e80a57792652264a356839f77ccd081c',
  ),
  (
    '<blockquote"</a><td><a <thead><thead>></a>x',
    '',
    '6c496a6f16fa1911a5c718202f35a1b2f69168b180368e7b88519070080a4d78',
  ),
  (
    '<tablea="b"',
    '"style=" <td></a><<x-mail::button ',
    'c894e19a1b2ceba8d4d0a31d430df31b0cd4cbe1bc56dfae2748d2165e88998d',
  ),
  (
    'x ',
    '\n',
    '01f7cd0df4793181ab70bb03173fd471021185cbc362b4a98e5ddf201c5d9e75',
  ),
  (
    '**</a><img a="b" ',
    '></a><x-mail::button <p  <blockquote',
    'be6be31cc1d2e0a1188fcda21a77eb9941ef316926ec4a102909527be1c7cdcb',
  ),
  (
    '</x-mail::button>',
    '<a style="c">-',
    '6fd641b17d5dd04617678edd40b68a1def9027f445e2ac4db66c120af6d0fae9',
  ),
  (
    '><p>=\n<h1<thead><thead>-',
    '-</x-mail::button> \n<img </a>a="b"',
    '38df15b30061953e6f1d6187b816b712ea5f7769b329d489ad1cf93d14e6aece',
  ),
  (
    '</a><a href="h"><a style="c"><table<a href="h"><p><p -<p>"',
    '<a </x-mail::button>',
    '10012ed216ef67b742d519aa1e81585d7d849576aca41353c9c78ee2f4ef5ba9',
  ),
  (
    '',
    'data-k="v" <blockquote<h1a="b"',
    'f989af49fadd32a226ac0e7b3e90acab4c3418f3394189b8ef33de2107a49432',
  ),
  (
    '<p>style="<thead><img <a href="h">-x"-<a ',
    '',
    'd71f290a50f8ae9667952a786089db5022e63a2e82c4b31508283f268f724926',
  ),
  (
    '<td>style="<blockquote<p " [l](t)',
    '<tablexx',
    '04da8f87d866f0e6e1c51d8666579031613fb3bbd2a44b24a075148acda985bc',
  ),
  (
    '**<td>-',
    '<x-mail::button url="u">a="b"<x-mail::button url="u"><img </a>=<p>"a="b"',
    '8943629c9587aa37d4213b6d5e87d5217899714524dd2abe6cdf1ee12c262f7d',
  ),
  (
    '',
    '[l](t)<x-mail::button <h10 </a><thead>a="b"',
    'fb4db78fb3e37bf26b8df0f31051128d4db65802d03c59782ae1c959139d3ebe',
  ),
  (
    ' -<a </a><x-mail::button url="u"><[l](t)-<p><a href="h"><h10',
    '<blockquote<a href="h">[l](t)',
    'aaf13240a6c46a211c3c781a3198babc28c395741b51545dfe40af124a5b9e43',
  ),
  (
    '<thead>**<=><',
    'x[l](t)-<h10=<<td> ',
    '1d71fa9f20846eccf1fefc55c154a6e89d394e0c97055c316208bbb93273f3d8',
  ),
  (
    '-<img \n<a style="c"> ',
    '<img <a href="h">',
    'fd2904836556023abe4386315782e46f04b5674feef929df2430f43601ae0218',
  ),
  (
    '</a><h1',
    'style="',
    '77ad26376c0e95f12e31dbbf8f08f185349082a7e6f58784f0a7239c3830c9d2',
  ),
  (
    'data-k="v" x<thead><x-mail::button <a <a ',
    'x"[l](t)>><a style="c"><thead>',
    'ce4ceaebcbb9ffe4d5f55f490cc345ac96a4f542678f2b5863a10c25ab6b0885',
  ),
  (
    '<x-mail::button <td>',
    '<p ""',
    'd7dcb0e1c490b6dbba2ec21b9a609589b5f4ad5f29ae80ed3250b8dcaaf4c5ed',
  ),
  (
    '= <h10-<table',
    '<table<td></a>=<thead>[l](t)[l](t)</a>xdata-k="v" <h10',
    'd26fae130fda3c38f7b9a2e40fe26a70b52b010554bc2c1ef418e20199f21dd3',
  ),
  (
    '</x-mail::button><h1>data-k="v" <img x<blockquote<thead><p >',
    'data-k="v" <h10"><\n=<thead><p ',
    '114ec2e9e2edb6eb13d7dc0625dce54c9a4a35ae89d55125355e8b84274cc927',
  ),
  (
    '<<',
    '<table<img <a style="c">a="b"<a href="h"><td>data-k="v" -<h1',
    'd16bf4920511307831c93dc37014c5f15a0b7d771b30f64354483d6170cdb921',
  ),
  (
    '<a="b"<h10=<td> **<>',
    '<h10"<p>[l](t)<p [l](t)<\n**',
    '3e8148526be4cbec89f0ebc1674f92d94643c3365e96e77db66be8fb4126535e',
  ),
  (
    '"<a style="c">[l](t)<x-mail::button url="u"><table</a><x-mail::button url="u"></x-mail::button>',
    '[l](t)',
    'aabdbc6f9e1c91f5bedb89b5bd1f1601facc83adf358bcc84b66c5fddf02551f',
  ),
  (
    '</x-mail::button>\ndata-k="v" <x-mail::button url="u"><h1<h1<p ',
    '</a><x-mail::button url="u">><a style="<a ',
    '10f0379e88cacf76408dcc53dce3a25caa9fe08add61bbddf725fb0aa54e0c04',
  ),
  (
    '<x-mail::button <h10<h1<a ',
    '</a>',
    '22fa76856ec28608c4a4ac2ea43d2af855e6fd0500ce098f08ff4b9005419699',
  ),
  (
    '<table<x-mail::button url="u"></a>x',
    '<td><blockquote\n<p><img **<td>>',
    '3a73dd9d27d3f80d931ea18fb010056820d941282e38f64fbf6338c9e25b0564',
  ),
  (
    '<a style="c">"<thead>',
    '<thead><blockquote<thead><img <x-mail::button >x**<p> </x-mail::button>',
    '26204c27a22c0a96dc25726718cb0297f0e5e6a69b63304c93f7f4cb94f187a1',
  ),
  (
    '<h10<blockquotex<blockquote<p>data-k="v" ',
    'style="<x-mail::button <a style="c">=<p><p ',
    '38d96beef02b568683bf00c31696aa4f3dba1e3c9d2d69014a9d7f0ae1ede3de',
  ),
  (
    'x<img xxstyle="',
    '<a style="',
    'ad6ae179b3220d55273f8d6d52cb0d61ccea48b0b2f351fc9ec0739bd60bf358',
  ),
  (
    '<h10<<a href="h"><<blockquote=>\n',
    '<td><x-mail::button xdata-k="v" <x-mail::button <td><h1a="b"<a  ',
    'a0a96d278f22779e14e71ddf8ea36987fe719d79f2ef0b428206a07322df14ac',
  ),
  (
    '<h1\n<h1',
    '<table<h10',
    '520ef3647afce67236e4892af4e2181100365741603a813aaf7fe9f8bc8a0240',
  ),
  (
    '=<blockquote',
    '<h1',
    'ed536c638e04e37e0e92549865dfade432374ab98f47d183038be9ae67e3a752',
  ),
  (
    '</x-mail::button>data-k="v" style="<h1"',
    '<x-mail::button url="u"><p>',
    '2aeab2fdee58a51f44c98fe700ceab2b05ba7fa0f65aa5707632ff5ced289aeb',
  ),
  (
    'a="b"<a style="c">**=<<a href="h"><thead><p>',
    '**',
    'dc2c6b870e1e8343fec7c79b152fe6a6bc85f7da9c3f83de4d2a660e1ed55e68',
  ),
  (
    '<h1-=a="b"[l](t)</x-mail::button><p <blockquote-><a ',
    '<p  <h1<h1-</x-mail::button><a style="c"><a ',
    '11c1f8b551d87d673324aee952a99d6d9433ddba70e0100792a7b568543a2189',
  ),
];
